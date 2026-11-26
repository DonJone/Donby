import Foundation
import DonbyCore

/// Intent-aware playback pre-provisioning coordinator (`DonbyNetwork` pure-core compatible).
/// Maintains a synchronous `0ms` in-memory `ResolvedPlaybackResource` fast table and orchestrates
/// zero-byte 4-lane TLS/H2 edge preconnects, shelf control-plane warmups, and 1.5 MiB episode micro-staging.
public final class PlaybackIntentCoordinator: @unchecked Sendable {
    public static let shared = PlaybackIntentCoordinator()

    private struct FastCacheEntry {
        var resource: ResolvedPlaybackResource
        var expiresAt: Date
    }

    private static let maxFastCacheEntries = 64
    private let lock = NSLock()
    private var fastCache: [String: FastCacheEntry] = [:]
    private var shelfWarmTask: Task<Void, Never>?
    private var candidateStageTask: Task<Void, Never>?
    private var candidateStageSignature: String?

    private init() {}

    // MARK: - Synchronous 0ms Resolved Resource Fast Cache (TTL 240s)

    private static func makeFastCacheKey(
        server: EmbyServerConfig,
        itemId: String,
        preferredSourceId: String?,
        preferredPreset: PreferredVersionPreset
    ) -> String {
        let canonicalItem = DonbyTurboCacheEngine.canonicalAssetIdComponent(itemId)
        let canonicalSource = preferredSourceId.map { DonbyTurboCacheEngine.canonicalAssetIdComponent($0) } ?? ""
        return "\(server.id.uuidString)|\(server.activeBaseURL)|\(canonicalItem)|\(canonicalSource)|\(preferredPreset.rawValue)"
    }

    public func cachedResolvedResource(
        server: EmbyServerConfig,
        itemId: String,
        preferredSourceId: String? = nil,
        preferredPreset: PreferredVersionPreset = .higherBitrate,
        enable302Cache: Bool = true
    ) -> ResolvedPlaybackResource? {
        let key = Self.makeFastCacheKey(
            server: server,
            itemId: itemId,
            preferredSourceId: preferredSourceId,
            preferredPreset: preferredPreset
        )
        let now = Date()
        var hit: ResolvedPlaybackResource? = nil
        lock.lock()
        if let entry = fastCache[key] {
            if entry.expiresAt > now {
                hit = entry.resource
            } else {
                fastCache.removeValue(forKey: key)
            }
        }
        lock.unlock()

        guard let resolved = hit else { return nil }
        // Automatically upgrade streamURL if a 302 CDN redirect was learned after the control-plane resolve
        if enable302Cache && server.cache302Request {
            let redirectKey = EmbyClient.redirectCacheKey(
                serverId: server.id,
                itemId: itemId,
                mediaSourceId: resolved.mediaSource.id,
                baseURL: server.activeBaseURL
            )
            if let warmRedirect = NetworkRouteWarmStore.shared.cachedRedirect(for: redirectKey),
               warmRedirect != resolved.streamURL {
                let origin = resolved.originStreamURL ?? resolved.streamURL
                return ResolvedPlaybackResource(
                    streamURL: warmRedirect,
                    originStreamURL: origin,
                    downloadURL: resolved.downloadURL,
                    headers: resolved.headers,
                    playSessionId: resolved.playSessionId,
                    mediaSource: resolved.mediaSource,
                    subtitleURLs: resolved.subtitleURLs,
                    isDirectStream: resolved.isDirectStream,
                    routeNote: resolved.routeNote.contains("302") ? resolved.routeNote : "\(resolved.routeNote) · 302缓存命中"
                )
            }
        }
        return resolved
    }

    public func storeResolvedResource(
        _ resource: ResolvedPlaybackResource,
        server: EmbyServerConfig,
        itemId: String,
        preferredSourceId: String? = nil,
        preferredPreset: PreferredVersionPreset = .higherBitrate,
        ttlSeconds: TimeInterval = 240
    ) {
        let now = Date()
        let expiry = now.addingTimeInterval(max(15, ttlSeconds))
        let primaryKey = Self.makeFastCacheKey(
            server: server,
            itemId: itemId,
            preferredSourceId: preferredSourceId,
            preferredPreset: preferredPreset
        )
        let concreteSourceKey = Self.makeFastCacheKey(
            server: server,
            itemId: itemId,
            preferredSourceId: resource.mediaSource.id,
            preferredPreset: preferredPreset
        )

        lock.lock()
        if fastCache.count >= Self.maxFastCacheEntries {
            fastCache = fastCache.filter { $0.value.expiresAt > now }
            if fastCache.count >= Self.maxFastCacheEntries,
               let oldest = fastCache.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
                fastCache.removeValue(forKey: oldest)
            }
        }
        fastCache[primaryKey] = FastCacheEntry(resource: resource, expiresAt: expiry)
        fastCache[concreteSourceKey] = FastCacheEntry(resource: resource, expiresAt: expiry)
        lock.unlock()
    }

    public func invalidateServer(_ serverId: UUID) {
        let prefix = "\(serverId.uuidString)|"
        lock.lock()
        fastCache = fastCache.filter { !$0.key.hasPrefix(prefix) }
        let sTask = shelfWarmTask
        let cTask = candidateStageTask
        shelfWarmTask = nil
        candidateStageTask = nil
        candidateStageSignature = nil
        lock.unlock()
        sTask?.cancel()
        cTask?.cancel()
        NetworkRouteWarmStore.shared.invalidateServer(serverId)
    }

    // MARK: - Unified Resolution + Edge Socket Prewarming

    public func resolveAndCacheResource(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String? = nil,
        preferredPreset: PreferredVersionPreset = .higherBitrate,
        audioStreamIndex: Int? = nil,
        subtitleStreamIndex: Int? = nil,
        enable302Cache: Bool = true,
        defer302ProbeWhenTurbo: Bool = true
    ) async throws -> ResolvedPlaybackResource {
        if audioStreamIndex == nil && subtitleStreamIndex == nil,
           let cached = cachedResolvedResource(
               server: server,
               itemId: item.id,
               preferredSourceId: preferredSourceId,
               preferredPreset: preferredPreset,
               enable302Cache: enable302Cache
           ) {
            DonbyNetworkSession.prewarmEdgeOrigin(cached.streamURL, laneCount: 4)
            return cached
        }

        let resolved: ResolvedPlaybackResource
        if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
            resolved = try await ext.resolvePlaybackResource(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId,
                preferredPreset: preferredPreset,
                enable302Cache: enable302Cache && server.cache302Request
            )
        } else {
            resolved = try await EmbyClient.shared.resolvePlaybackResource(
                server: server,
                item: item,
                preferredSourceId: preferredSourceId,
                preferredPreset: preferredPreset,
                audioStreamIndex: audioStreamIndex,
                subtitleStreamIndex: subtitleStreamIndex,
                enable302Cache: enable302Cache,
                defer302ProbeWhenTurbo: defer302ProbeWhenTurbo
            )
        }
        storeResolvedResource(
            resolved,
            server: server,
            itemId: item.id,
            preferredSourceId: preferredSourceId,
            preferredPreset: preferredPreset
        )
        DonbyNetworkSession.prewarmEdgeOrigin(resolved.streamURL, laneCount: 4)
        if let origin = resolved.originStreamURL, origin.host != resolved.streamURL.host {
            DonbyNetworkSession.prewarmEdgeOrigin(origin, laneCount: 2)
        }
        return resolved
    }

    // MARK: - Tier 1: Zero-Byte 4-Lane TLS/H2 Preconnect on Launch / Server Open / Line Switch

    public func warmServerOnConnectOrLaunch(server: EmbyServerConfig) {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let lineKey = server.selectedLineId?.uuidString ?? "main"
        if let cachedEdge = NetworkRouteWarmStore.shared.cachedEdgeOrigin(serverId: server.id, lineKey: lineKey) {
            DonbyNetworkSession.prewarmEdgeOrigin(cachedEdge, laneCount: 4)
        }
        Task.detached(priority: .utility) {
            if let ext = DonbyMediaServiceRegistry.shared.provider(for: server.type) {
                let edgeURLs = await ext.prewarmEdgeRoutes(server: server)
                for edgeURL in edgeURLs {
                    NetworkRouteWarmStore.shared.storeEdgeOrigin(edgeURL, serverId: server.id, lineKey: lineKey)
                    DonbyNetworkSession.prewarmEdgeOrigin(edgeURL, laneCount: 4)
                }
            } else {
                await EmbyClient.shared.prewarmConnection(server: server)
                if let baseURL = URL(string: server.activeBaseURL) {
                    DonbyNetworkSession.prewarmEdgeOrigin(baseURL, laneCount: 4)
                }
            }
        }
    }

    // MARK: - Tier 2: Home Continue-Watching Control-Plane Warmup (Top 2 Items, Zero Video Bytes)

    public func warmShelfCandidates(
        server: EmbyServerConfig,
        items: [EmbyItem],
        preferredPreset: PreferredVersionPreset = .higherBitrate,
        enable302Cache: Bool = true
    ) {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let targets = Array(items.filter { !$0.isSeries }.prefix(2))
        guard !targets.isEmpty else { return }

        lock.lock()
        let prev = shelfWarmTask
        shelfWarmTask = nil
        lock.unlock()
        prev?.cancel()

        let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled, let self else { return }
            for target in targets {
                guard !Task.isCancelled else { return }
                if await DonbyDownloadManager.shared.completedEntry(for: target.id, serverId: server.id) != nil {
                    continue
                }
                _ = try? await self.resolveAndCacheResource(
                    server: server,
                    item: target,
                    preferredPreset: preferredPreset,
                    enable302Cache: enable302Cache,
                    defer302ProbeWhenTurbo: true
                )
            }
        }

        lock.lock()
        shelfWarmTask = task
        lock.unlock()
    }

    // MARK: - Tier 3: Hover / Focus / Near-End Candidate Episode Micro-Staging (1.5 - 2.5 MiB)

    public func stageCandidateEpisode(
        server: EmbyServerConfig,
        item: EmbyItem,
        startSeconds: Double = 0,
        preferredPreset: PreferredVersionPreset = .higherBitrate,
        enable302Cache: Bool = true,
        turboEnabled: Bool = true,
        debounceNanoseconds: UInt64 = 180_000_000,
        maxMemoryBytes: Int = 268_435_456
    ) {
        guard !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !item.isSeries else { return }
        let sig = "\(server.id.uuidString)|\(item.id)|\(Int(startSeconds))"
        lock.lock()
        if candidateStageSignature == sig && candidateStageTask != nil {
            lock.unlock()
            return
        }
        let prev = candidateStageTask
        candidateStageTask = nil
        candidateStageSignature = sig
        lock.unlock()
        prev?.cancel()

        let task: Task<Void, Never> = Task.detached(priority: .utility) { [weak self] in
            await self?.executeCandidateStage(
                server: server,
                item: item,
                startSeconds: startSeconds,
                preferredPreset: preferredPreset,
                enable302Cache: enable302Cache,
                turboEnabled: turboEnabled,
                debounceNanoseconds: debounceNanoseconds,
                maxMemoryBytes: maxMemoryBytes
            )
        }

        lock.lock()
        candidateStageTask = task
        lock.unlock()
    }

    private func executeCandidateStage(
        server: EmbyServerConfig,
        item: EmbyItem,
        startSeconds: Double,
        preferredPreset: PreferredVersionPreset,
        enable302Cache: Bool,
        turboEnabled: Bool,
        debounceNanoseconds: UInt64,
        maxMemoryBytes: Int
    ) async {
        if debounceNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
        }
        guard !Task.isCancelled else { return }
        if await DonbyDownloadManager.shared.completedEntry(for: item.id, serverId: server.id) != nil {
            return
        }
        guard let res = try? await resolveAndCacheResource(
            server: server,
            item: item,
            preferredPreset: preferredPreset,
            enable302Cache: enable302Cache,
            defer302ProbeWhenTurbo: true
        ), !Task.isCancelled else { return }

        guard turboEnabled else { return }
        let urlLower = res.streamURL.absoluteString.lowercased()
        guard (urlLower.hasPrefix("http://") || urlLower.hasPrefix("https://")),
              !urlLower.contains(".m3u8"),
              !urlLower.contains(".mpd") else { return }

        let assetKey = DonbyTurboCacheEngine.makeAssetKey(
            serverId: server.id,
            itemId: item.id,
            mediaSourceId: res.mediaSource.id
        )
        let redirectKey = EmbyClient.redirectCacheKey(
            serverId: server.id,
            itemId: item.id,
            mediaSourceId: res.mediaSource.id,
            baseURL: server.activeBaseURL
        )
        let originURL = res.originStreamURL ?? res.streamURL
        let cachedRedirect: URL? = (res.originStreamURL != nil && res.originStreamURL != res.streamURL)
            ? res.streamURL
            : NetworkRouteWarmStore.shared.cachedRedirect(for: redirectKey)
        let durationSec = Double(item.runTimeTicks ?? res.mediaSource.runTimeTicks ?? 0) / 10_000_000.0
        let shouldSave302 = enable302Cache && server.cache302Request
        let redirectHandler: (@Sendable (URL) -> Void)? = shouldSave302
            ? Self.makeRedirectStoreHandler(key: redirectKey)
            : nil

        DonbyTurboCacheEngine.shared.startMicroStagePreload(
            assetKey: assetKey,
            streamURL: originURL,
            cachedRedirectURL: cachedRedirect,
            headers: res.headers,
            knownTotalSize: res.mediaSource.size,
            durationSeconds: durationSec,
            startPositionSeconds: startSeconds,
            maxMemoryBytes: maxMemoryBytes,
            onResolvedRedirectURL: redirectHandler
        )
    }

    private static func makeRedirectStoreHandler(key: String) -> @Sendable (URL) -> Void {
        { finalURL in
            Task {
                await RedirectCacheStore.shared.storeRedirect(finalURL, for: key)
            }
        }
    }
}

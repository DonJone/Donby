import Foundation

public enum DonbyPlaybackReportKind: String, Sendable {
    case progress
    case stopped
    case finished
}

/// Extension seam allowing optional service modules (such as DonbyUHDModule)
/// to register protocol-specific API providers without hard-coupling DonbyCore or DonbyNetwork.
public protocol DonbyMediaServiceProvider: Sendable {
    var serverType: ServerType { get }

    func fetchItemDetail(server: EmbyServerConfig, item: EmbyItem) async throws -> EmbyItem
    func resolvePlaybackResource(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String?,
        preferredPreset: PreferredVersionPreset,
        enable302Cache: Bool
    ) async throws -> ResolvedPlaybackResource
    func fetchSeasons(server: EmbyServerConfig, tvId: String) async throws -> [EmbyItem]
    func fetchSeasonEpisodes(
        server: EmbyServerConfig,
        tvId: String,
        seasonId: String,
        seasonNumber: Int?,
        seriesName: String?
    ) async throws -> [EmbyItem]
    func search(server: EmbyServerConfig, query: String, limit: Int) async throws -> (items: [EmbyItem], truncated: Bool)
    func prewarmPlayback(server: EmbyServerConfig, item: EmbyItem?) async
    func reportPlayback(
        server: EmbyServerConfig,
        kind: DonbyPlaybackReportKind,
        item: EmbyItem,
        assetId: String,
        positionSeconds: Double
    ) async
    func setFavorite(server: EmbyServerConfig, item: EmbyItem, isFavorite: Bool) async throws
    func setPlayed(server: EmbyServerConfig, item: EmbyItem, isPlayed: Bool) async throws
    func pingLine(server: EmbyServerConfig, line: ServerLineInfo?) async -> Int?
    func invalidateCaches(serverId: UUID) async
}

/// Thread-safe runtime registry for optional media service modules.
public final class DonbyMediaServiceRegistry: @unchecked Sendable {
    public static let shared = DonbyMediaServiceRegistry()

    private let lock = NSLock()
    private var providers: [ServerType: DonbyMediaServiceProvider] = [:]

    private init() {}

    public func register(_ provider: DonbyMediaServiceProvider) {
        lock.lock()
        providers[provider.serverType] = provider
        lock.unlock()
    }

    public func unregister(serverType: ServerType) {
        lock.lock()
        providers.removeValue(forKey: serverType)
        lock.unlock()
    }

    public func provider(for serverType: ServerType) -> DonbyMediaServiceProvider? {
        lock.lock()
        defer { lock.unlock() }
        return providers[serverType]
    }

    public func isRegistered(_ serverType: ServerType) -> Bool {
        provider(for: serverType) != nil
    }
}

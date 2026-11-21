import Foundation
import DonbyCore
import DonbyNetwork

public enum UHDAuthFallbackKind: Sendable {
    case password
    case loginCode
    case token
}

public struct UHDResolvedLoginOutcome: Sendable {
    public let auth: UHDLoginResult
    public let baseURL: String
    public let host: String
    public let isHttps: Bool
    public let port: Int
    public let usedChinaOptimizedEndpoint: Bool

    public init(
        auth: UHDLoginResult,
        baseURL: String,
        host: String,
        isHttps: Bool,
        port: Int,
        usedChinaOptimizedEndpoint: Bool
    ) {
        self.auth = auth
        self.baseURL = baseURL
        self.host = host
        self.isHttps = isHttps
        self.port = port
        self.usedChinaOptimizedEndpoint = usedChinaOptimizedEndpoint
    }
}

public struct UHDResolvedTokenOutcome: Sendable {
    public let subscription: UHDSubscriptionInfo
    public let baseURL: String
    public let host: String
    public let isHttps: Bool
    public let port: Int
    public let usedChinaOptimizedEndpoint: Bool

    public init(
        subscription: UHDSubscriptionInfo,
        baseURL: String,
        host: String,
        isHttps: Bool,
        port: Int,
        usedChinaOptimizedEndpoint: Bool
    ) {
        self.subscription = subscription
        self.baseURL = baseURL
        self.host = host
        self.isHttps = isHttps
        self.port = port
        self.usedChinaOptimizedEndpoint = usedChinaOptimizedEndpoint
    }
}

/// Official endpoint routing & China-optimized line selection policy for the optional UHDNow module.
public enum UHDModuleEndpoints {
    public static let primaryChinaOptimizedBaseURL = "https://smart.uhdnow.com"
    public static let primaryChinaOptimizedHost = "smart.uhdnow.com"
    public static let fallbackStandardBaseURL = "https://v1.uhdnow.com"
    public static let fallbackStandardHost = "v1.uhdnow.com"

    public static func candidateBaseURLs(customBaseURL: String?) -> [String] {
        let trimmed = customBaseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty {
            let normalized = ServerLineInfo.normalizeBaseURL(
                trimmed.contains("://") ? trimmed : "https://\(trimmed)"
            )
            return normalized.isEmpty ? [primaryChinaOptimizedBaseURL, fallbackStandardBaseURL] : [normalized]
        }
        return [primaryChinaOptimizedBaseURL, fallbackStandardBaseURL]
    }

    public static func isChinaOptimizedHost(_ rawURLOrHost: String) -> Bool {
        let lower = extractHost(from: rawURLOrHost).lowercased()
        guard !lower.isEmpty else { return false }
        if lower == primaryChinaOptimizedHost || lower == "speed.uhdnow.com" {
            return true
        }
        if lower.hasSuffix(".uhdnow.online") || lower == "uhdnow.online" {
            return true
        }
        if lower.contains("smart.uhd") || lower.contains("cn.") || lower.contains("-cn") {
            return true
        }
        return false
    }

    public static func isChinaOptimizedLine(_ line: ServerLineInfo) -> Bool {
        if isChinaOptimizedHost(line.url) {
            return true
        }
        let lowerName = line.name.lowercased()
        let chineseOptimizedKeywords = [
            "中国", "优化", "直连", "大陆", "国内", "回国", "专线",
            "cn cdn", "smart", "china", "direct", "cn2", "iepl", "iplc", "bgp"
        ]
        return chineseOptimizedKeywords.contains { lowerName.contains($0) }
    }

    /// Picks the default playback line for a UHD account:
    /// - If the user has a China-optimized plan (authenticated via `smart.uhdnow.com` or entitled to any China-optimized line),
    ///   automatically selects the highest-priority China-optimized line.
    /// - Otherwise selects the first server-ordered playback line.
    public static func pickPreferredDefaultLine(
        from lines: [ServerLineInfo],
        loggedInBaseURL: String
    ) -> ServerLineInfo? {
        guard !lines.isEmpty else { return nil }
        let preferChina = isChinaOptimizedHost(loggedInBaseURL) || lines.contains(where: { isChinaOptimizedLine($0) })
        if preferChina, let chinaLine = lines.first(where: { isChinaOptimizedLine($0) }) {
            return chinaLine
        }
        return lines.first
    }

    public static func shouldFallbackToStandardEndpoint(
        after error: Error,
        authKind: UHDAuthFallbackKind
    ) -> Bool {
        if error is CancellationError {
            return false
        }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if let clientError = error as? EmbyClientError {
            switch clientError {
            case .httpStatus(let code, _):
                switch authKind {
                case .loginCode:
                    // Per streaming-api.md, 401 means the single-use 8-digit code is invalid/expired/already consumed.
                    return code == 403 || code == 404 || code == 429 || code >= 500
                case .password, .token:
                    // Non-China-optimized accounts may receive 403/404 (or 401 domain denial) on smart.uhdnow.com.
                    return code == 401 || code == 403 || code == 404 || code == 429 || code >= 500
                }
            case .unauthorized:
                return authKind != .loginCode
            case .invalidServerURL, .emptyToken, .noPlayableStream, .decodingFailed:
                return true
            }
        }
        return true
    }

    public static func parseEndpointComponents(from baseURL: String) -> (host: String, isHttps: Bool, port: Int) {
        let normalized = ServerLineInfo.normalizeBaseURL(baseURL)
        let withScheme = normalized.contains("://") ? normalized : "https://\(normalized)"
        if let comps = URLComponents(string: withScheme), let host = comps.host, !host.isEmpty {
            let isHttps = (comps.scheme?.lowercased() ?? "https") != "http"
            let port = comps.port ?? (isHttps ? 443 : 80)
            return (host, isHttps, port)
        }
        return (extractHost(from: normalized), true, 443)
    }

    private static func extractHost(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.contains("://"), let host = URLComponents(string: trimmed)?.host {
            return host
        }
        let noPath = trimmed.split(separator: "/").first.map(String.init) ?? trimmed
        return noPath.split(separator: ":").first.map(String.init) ?? noPath
    }
}

/// Optional service provider implementation bridged into DonbyCore's DonbyMediaServiceRegistry.
public final class DonbyUHDServiceProvider: DonbyMediaServiceProvider, @unchecked Sendable {
    public static let shared = DonbyUHDServiceProvider()
    public let serverType: ServerType = .uhdNative

    private init() {}

    public func fetchItemDetail(server: EmbyServerConfig, item: EmbyItem) async throws -> EmbyItem {
        try await UHDStreamClient.shared.fetchItemDetail(server: server, item: item)
    }

    public func resolvePlaybackResource(
        server: EmbyServerConfig,
        item: EmbyItem,
        preferredSourceId: String?,
        preferredPreset: PreferredVersionPreset,
        enable302Cache: Bool
    ) async throws -> ResolvedPlaybackResource {
        try await UHDStreamClient.shared.resolvePlaybackResource(
            server: server,
            item: item,
            preferredSourceId: preferredSourceId,
            preferredPreset: preferredPreset,
            enable302Cache: enable302Cache
        )
    }

    public func fetchSeasons(server: EmbyServerConfig, tvId: String) async throws -> [EmbyItem] {
        try await UHDStreamClient.shared.fetchSeasons(server: server, tvId: tvId)
    }

    public func fetchSeasonEpisodes(
        server: EmbyServerConfig,
        tvId: String,
        seasonId: String,
        seasonNumber: Int?,
        seriesName: String?
    ) async throws -> [EmbyItem] {
        try await UHDStreamClient.shared.fetchSeasonEpisodes(
            server: server,
            tvId: tvId,
            seasonId: seasonId,
            seasonNumber: seasonNumber,
            seriesName: seriesName
        ).items
    }

    public func search(server: EmbyServerConfig, query: String, limit: Int) async throws -> (items: [EmbyItem], truncated: Bool) {
        try await UHDStreamClient.shared.searchWithMeta(server: server, query: query, limit: limit)
    }

    public func prewarmPlayback(server: EmbyServerConfig, item: EmbyItem?) async {
        await UHDStreamClient.shared.prewarmPlaybackDomain(server: server)
        if let item, item.isEpisode {
            _ = try? await UHDStreamClient.shared.fetchAssetMediaSources(server: server, item: item)
        }
    }

    public func reportPlayback(
        server: EmbyServerConfig,
        kind: DonbyPlaybackReportKind,
        item: EmbyItem,
        assetId: String,
        positionSeconds: Double
    ) async {
        let uhdKind: UHDStreamClient.PlaybackReportKind = switch kind {
        case .progress: .progress
        case .stopped: .stopped
        case .finished: .finished
        }
        await UHDStreamClient.shared.reportPlayback(
            server: server,
            kind: uhdKind,
            item: item,
            assetId: assetId,
            positionSeconds: positionSeconds
        )
    }

    public func setFavorite(server: EmbyServerConfig, item: EmbyItem, isFavorite: Bool) async throws {
        try await UHDStreamClient.shared.setFavorite(server: server, item: item, isFavorite: isFavorite)
    }

    public func setPlayed(server: EmbyServerConfig, item: EmbyItem, isPlayed: Bool) async throws {
        try await UHDStreamClient.shared.setPlayed(server: server, item: item, isPlayed: isPlayed)
    }

    public func pingLine(server: EmbyServerConfig, line: ServerLineInfo?) async -> Int? {
        await UHDStreamClient.shared.pingLine(server: server, line: line)
    }

    public func invalidateCaches(serverId: UUID) async {
        await UHDStreamClient.shared.invalidateResolvedDomainCache(serverId: serverId)
    }
}

/// Lifecycle entry point for installing / uninstalling the optional UHDNow module at runtime.
public enum DonbyUHDModule {
    public static func install() {
        DonbyMediaServiceRegistry.shared.register(DonbyUHDServiceProvider.shared)
    }

    public static func uninstall() {
        DonbyMediaServiceRegistry.shared.unregister(serverType: .uhdNative)
    }

    public static var isInstalled: Bool {
        DonbyMediaServiceRegistry.shared.isRegistered(.uhdNative)
    }
}

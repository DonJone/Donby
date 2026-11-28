import SwiftUI
import Combine
import DonbyCore
import DonbyNetwork

// MARK: - Core-Owned Extension Data Contracts (Zero Service-Specific Coupling)

public struct DonbyExtensionLibraryPage {
    public let items: [EmbyItem]
    public let nextCursor: String?
    public let hasMore: Bool
    public let totalOverride: Int?

    public init(items: [EmbyItem], nextCursor: String?, hasMore: Bool, totalOverride: Int?) {
        self.items = items
        self.nextCursor = nextCursor
        self.hasMore = hasMore
        self.totalOverride = totalOverride
    }
}

public struct DonbyExtensionDetailPayload {
    public let enrichedItem: EmbyItem?
    public let seasons: [EmbyItem]?
    public let preferredEpisode: (seasonId: String, seasonNumber: Int?, episodeId: String)?

    public init(
        enrichedItem: EmbyItem?,
        seasons: [EmbyItem]?,
        preferredEpisode: (seasonId: String, seasonNumber: Int?, episodeId: String)?
    ) {
        self.enrichedItem = enrichedItem
        self.seasons = seasons
        self.preferredEpisode = preferredEpisode
    }
}

public struct DonbyPlayerStateSnapshot {
    public let isPlaying: Bool
    public let hasRenderedFirstFrame: Bool
    public let isOpeningMedia: Bool
    public let playbackSpeed: Float
    public let liveCurrentTime: Double
    public let currentMediaSourceId: String

    public init(
        isPlaying: Bool,
        hasRenderedFirstFrame: Bool,
        isOpeningMedia: Bool,
        playbackSpeed: Float,
        liveCurrentTime: Double,
        currentMediaSourceId: String
    ) {
        self.isPlaying = isPlaying
        self.hasRenderedFirstFrame = hasRenderedFirstFrame
        self.isOpeningMedia = isOpeningMedia
        self.playbackSpeed = playbackSpeed
        self.liveCurrentTime = liveCurrentTime
        self.currentMediaSourceId = currentMediaSourceId
    }
}

// MARK: - Player Companion Lifecycle Contract

@MainActor
public protocol DonbyPlayerCompanion: AnyObject {
    var showsCompanionDrawerTab: Bool { get }

    func bindDriver(
        pauseAndGetPosition: @escaping () -> Double,
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        seekAccurate: @escaping (Double) -> Void,
        setRate: @escaping (Float) -> Void,
        switchMedia: @escaping (EmbyItem, ResolvedPlaybackResource, Double) -> Void,
        snapshot: @escaping () -> DonbyPlayerStateSnapshot
    )

    func onAppear()
    func onMediaOrFirstFrameChanged(
        item: EmbyItem,
        mediaSource: MediaSourceInfo,
        enableDanmaku: Bool,
        hasRenderedFirstFrame: Bool
    ) async
    func onProgressTick(
        nowUptime: TimeInterval,
        livePos: Double,
        isPlaying: Bool,
        hasRenderedFirstFrame: Bool,
        isOpeningMedia: Bool,
        isWaitingForSeekOrBuffer: Bool,
        didHandlePlaybackEnded: Bool,
        playbackSpeed: Float
    )
    func onPlaybackEnded(livePos: Double, playbackSpeed: Float)
    func onLocalPlayPauseChanged(isPlaying: Bool, livePos: Double, playbackSpeed: Float)
    func onLocalSeek(seconds: Double, isPlaying: Bool, playbackSpeed: Float)
    func onLocalRateChanged(rate: Double, isPlaying: Bool, livePos: Double)
    func onLocalEpisodeSwitched(assetId: String, positionSeconds: Double, playbackSpeed: Float)
    func onPlayerClose()

    func makeVideoOverlay(
        isEnabled: Bool,
        isPlaying: Bool,
        playbackRate: Double,
        timeProvider: @escaping () -> (Double, TimeInterval)
    ) -> AnyView
    func makeTopBarControls(activeDrawer: Binding<PlayerDrawerTab?>) -> AnyView
    func makeContextMenuItems(activeDrawer: Binding<PlayerDrawerTab?>) -> AnyView
    func makeDrawerContent(accentTint: Color) -> AnyView
    func wrapPlayerSheets(_ content: AnyView, currentItem: EmbyItem, currentMediaSource: MediaSourceInfo) -> AnyView
}

@MainActor
public final class DonbyPlayerCompanionBox: ObservableObject {
    public private(set) var companion: (any DonbyPlayerCompanion)?

    public init() {}

    public func configureIfNeeded(server: EmbyServerConfig, appState: AppState) {
        guard companion == nil else { return }
        if let created = DonbyAppExtensionCenter.shared.plugin?.makePlayerCompanion(
            server: server,
            appState: appState,
            notifyHost: { [weak self] in
                self?.objectWillChange.send()
            }
        ) {
            companion = created
            objectWillChange.send()
        }
    }
}

// MARK: - Optional UI Extension Plugin Contract

@MainActor
public protocol DonbyAppUIExtensionPlugin: AnyObject {
    var isEnabled: Bool { get }
    func isActive(for server: EmbyServerConfig?) -> Bool

    // AppState & Server Session Hooks
    func extraHomeItemLists() -> [[EmbyItem]]
    func resetHomeShelves()
    /// Returns explicit anime-hall state (`true` = Anime Hall, `false` = Normal Hall) when this plugin owns the server, or `nil` for standard Emby auto-detection.
    func isAnimeModeActive(for server: EmbyServerConfig) -> Bool?
    /// Lazily resolves missing `imdbId`s (mapped by `EmbyItem.id`) for extension items that only carry `tmdbId` in summary payloads.
    func resolveImdbIds(for items: [EmbyItem], server: EmbyServerConfig, maxCount: Int) async -> [String: String]
    func authenticateAndConfigureServer(
        draft: EmbyServerConfig,
        loginCode: String?,
        customEndpointOverride: String?,
        autoSyncDomains: Bool,
        appState: AppState
    ) async throws -> (server: EmbyServerConfig, usedChinaOptimizedLine: Bool)
    func syncPlaybackDomains(for serverId: UUID, appState: AppState, showFeedback: Bool) async
    func loadHomeContent(
        for server: EmbyServerConfig,
        appState: AppState,
        isCurrentGeneration: @escaping () -> Bool
    ) async
    func resolveSeriesStartEpisode(
        server: EmbyServerConfig,
        seriesItem: EmbyItem
    ) async throws -> (episodes: [EmbyItem], preferredTarget: EmbyItem?)
    func refreshAccountSnapshot(for server: EmbyServerConfig, appState: AppState) async
    func refreshMissingAccountSnapshots(servers: [EmbyServerConfig], appState: AppState) async

    // Server Card & Config Helpers
    func serverCardBadgeText(for server: EmbyServerConfig) -> String?
    func preferredEditorType(forUnconfigured server: EmbyServerConfig) -> ServerType?
    func initialCustomEndpoint(for server: EmbyServerConfig) -> String
    func applyCustomEndpointOnSaveOnly(_ customEndpoint: String, to draft: inout EmbyServerConfig)
    func formatLoginCodeDisplay(_ raw: String) -> String
    func isValidLoginCode(_ raw: String) -> Bool

    // Browse & Detail Hooks
    func homeShelves(for server: EmbyServerConfig?) -> [HomeShelfSection]
    func fetchAvailableGenres(for server: EmbyServerConfig) async -> [String]?
    func fetchLibraryPage(
        server: EmbyServerConfig,
        library: EmbyItem,
        query: String,
        sortField: EmbySortField,
        ascending: Bool,
        filterUnwatchedOnly: Bool,
        filterFavoritesOnly: Bool,
        selectedGenreFilter: String,
        cursor: String?
    ) async throws -> DonbyExtensionLibraryPage
    func loadDetailPayload(
        server: EmbyServerConfig,
        initialItem: EmbyItem,
        targetSeriesId: String?
    ) async -> DonbyExtensionDetailPayload
    func openPersonSheet(server: EmbyServerConfig, person: EmbyPerson)

    // Standard Donby View Slots
    func wrapRootSheets(_ content: AnyView) -> AnyView
    func makeSettingsCard() -> AnyView
    func makeEmbyToolbarButtons(server: EmbyServerConfig) -> AnyView
    func makeServerContextMenuExtraItems(server: EmbyServerConfig) -> AnyView
    func makeServerLogoutMenuItem(server: EmbyServerConfig) -> AnyView
    func makeCustomLineSwitchView(serverId: UUID, onDismiss: @escaping () -> Void) -> AnyView?
    func makeDetailWatchPartyCreateSheet(server: EmbyServerConfig, item: EmbyItem, preferredSourceId: String?) -> AnyView
    func makePlayerCompanion(
        server: EmbyServerConfig,
        appState: AppState,
        notifyHost: @escaping () -> Void
    ) -> (any DonbyPlayerCompanion)?

    // Optional Metadata Cache Hooks
    func metadataCacheSizeBytes() async -> Int64
    func clearMetadataCacheAsync() async
}

public extension DonbyAppUIExtensionPlugin {
    func metadataCacheSizeBytes() async -> Int64 { 0 }
    func clearMetadataCacheAsync() async {}
}

// MARK: - Central Extension Coordinator (Single Registration Seam)

@MainActor
public final class DonbyAppExtensionCenter: ObservableObject {
    public static let shared = DonbyAppExtensionCenter()

    public private(set) var plugin: (any DonbyAppUIExtensionPlugin)?
    private var didBootstrap = false

    private init() {}

    public func register(_ plugin: any DonbyAppUIExtensionPlugin) {
        self.plugin = plugin
        objectWillChange.send()
    }

    public var isEnabled: Bool {
        plugin?.isEnabled ?? false
    }

    public func isActive(for server: EmbyServerConfig?) -> Bool {
        plugin?.isActive(for: server) ?? false
    }

    /// Single compile-time seam in the entire core app target.
    /// Building with DONBY_PURE=1 omits DonbyUHDModule and excludes Sources/DonbyApp/Modules/UHD.
    public func installCompiledExtensionsIfNeeded() {
        guard !didBootstrap else { return }
        didBootstrap = true
        #if canImport(DonbyUHDModule) && !DONBY_PURE_BUILD
        UHDAppExtensionPlugin.registerIfNeeded()
        #endif
    }
}

// MARK: - Core Donby View Slot Wrappers & Shared Cinema Drawer Primitives

public struct DonbyExtensionSettingsCard: View {
    @ObservedObject private var extCenter = DonbyAppExtensionCenter.shared

    public init() {}

    public var body: some View {
        if let plugin = extCenter.plugin {
            plugin.makeSettingsCard()
        }
    }
}

private struct DonbyExtensionSheetsModifier: ViewModifier {
    @ObservedObject private var extCenter = DonbyAppExtensionCenter.shared

    func body(content: Content) -> some View {
        // Attach extension sheets on a zero-impact background host so plugin registration
        // never flips conditional identity around `content` or tears down its view subtree.
        content
            .background {
                if let plugin = extCenter.plugin {
                    plugin.wrapRootSheets(AnyView(Color.clear.allowsHitTesting(false)))
                }
            }
    }
}

public extension View {
    func donbyExtensionSheets() -> some View {
        modifier(DonbyExtensionSheetsModifier())
    }
}

public struct PlayerCompanionSheetsModifier: ViewModifier {
    @ObservedObject public var box: DonbyPlayerCompanionBox
    public let currentItem: EmbyItem
    public let currentMediaSource: MediaSourceInfo

    public init(box: DonbyPlayerCompanionBox, currentItem: EmbyItem, currentMediaSource: MediaSourceInfo) {
        self.box = box
        self.currentItem = currentItem
        self.currentMediaSource = currentMediaSource
    }

    public func body(content: Content) -> some View {
        // Keep `content` (PlayerView's ZStack + onAppear/onDisappear) structurally stable;
        // wrapping `content` in `if/else` would tear down and re-mount playback on first companion update.
        content
            .background {
                if let companion = box.companion {
                    companion.wrapPlayerSheets(
                        AnyView(Color.clear.allowsHitTesting(false)),
                        currentItem: currentItem,
                        currentMediaSource: currentMediaSource
                    )
                }
            }
    }
}

/// Canonical Donby dark cinema drawer card shared across core PlayerView and extension drawers.
public struct PlayerDrawerGlassCard<Content: View>: View {
    private let content: Content

    public init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            content
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.055))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.white.opacity(0.09), lineWidth: 0.65)
        )
    }
}

/// Canonical Donby dark cinema drawer row background shared across core PlayerView and extension drawers.
public struct PlayerDrawerRowBackground: View {
    public let isSelected: Bool
    public let isMonochromeTheme: Bool
    public let accentColor: Color

    public init(isSelected: Bool, isMonochromeTheme: Bool, accentColor: Color) {
        self.isSelected = isSelected
        self.isMonochromeTheme = isMonochromeTheme
        self.accentColor = accentColor
    }

    public var body: some View {
        let fill: Color = {
            if !isSelected { return Color.white.opacity(0.045) }
            return isMonochromeTheme ? Color.white.opacity(0.18) : accentColor.opacity(0.24)
        }()
        let stroke: Color = {
            if !isSelected { return Color.white.opacity(0.06) }
            return isMonochromeTheme ? Color.white.opacity(0.36) : accentColor.opacity(0.68)
        }()
        RoundedRectangle(cornerRadius: 9, style: .continuous)
            .fill(fill)
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(stroke, lineWidth: isSelected ? 0.85 : 0.55)
            )
    }
}

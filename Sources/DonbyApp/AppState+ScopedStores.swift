import SwiftUI
import DonbyCore
import DonbyNetwork

@MainActor
public final class DonbyDownloadStatusStore: ObservableObject {
    @Published public var statusIndex: DonbyDownloadStatusIndex = .empty

    public init() {}
}

@MainActor
public final class DonbySearchStore: ObservableObject {
    @Published public var globalSearchQuery: String = ""
    @Published public var globalSearchRemoteResults: [EmbyItem] = []
    @Published public var globalSearchRemoteScopeKey: String = ""

    public init() {}
}

@MainActor
public final class DonbyRatingsStore: ObservableObject {
    @Published public var multiPlatformRatingsByItemId: [String: MultiPlatformRatings] = [:]

    public init() {}
}

@MainActor
public final class DonbyWatchHistoryStore: ObservableObject {
    @Published public var watchHistory: [WatchRecordItem] = []

    public init() {}
}

extension AppState {
    func performBatchedHomeShelfUpdate(_ body: () -> Void) {
        let wasBatching = isBatchUpdatingHomeShelves
        isBatchUpdatingHomeShelves = true
        defer { isBatchUpdatingHomeShelves = wasBatching }
        body()
        if !wasBatching && !isLoadingFromDisk && !isSuppressingHomeShelfRefresh && openedServerId != nil {
            refreshCachedHomeShelvesIfNeeded()
        }
    }

    func performWithoutHomeShelfRefresh(_ body: () -> Void) {
        let wasSuppressing = isSuppressingHomeShelfRefresh
        isSuppressingHomeShelfRefresh = true
        defer { isSuppressingHomeShelfRefresh = wasSuppressing }
        body()
    }

    func mergeRatingsBatch(_ updates: [String: MultiPlatformRatings]) {
        guard !updates.isEmpty else { return }
        var merged = ratingsStore.multiPlatformRatingsByItemId
        var didChange = false
        for (itemId, rating) in updates {
            if merged[itemId] != rating {
                merged[itemId] = rating
                didChange = true
            }
        }
        if didChange {
            ratingsStore.multiPlatformRatingsByItemId = merged
        }
    }

    public func openServer(_ server: EmbyServerConfig) {
        cancelPendingPlaybackStart()
        homeCurationGeneration &+= 1
        let isSwitchingServer = (openedServerId != server.id)
        selectedLibrary = nil
        detailStack.removeAll()
        detailOfflineFocusIds.removeAll()
        detailFocusedEpisodeMemory.removeAll()
        homeErrorMessage = nil
        inFlightSeriesNameTasks.removeAll()
        if isSwitchingServer {
            embyInlineSearchQuery = ""
            embyInlineSearchResults = []
            embyInlineSearchTruncated = false
            embyInlineSearchLastServerId = nil
            embyInlineSearchLastFetchedQuery = ""
            librarySearchQueryById.removeAll()
            DonbyAppExtensionCenter.shared.plugin?.resetHomeShelves()
        }

        // Instantaneous switch from in-memory snapshot; fall back to off-main-thread disk decode on miss
        if let snap = ServerHomeCacheStore.shared.cachedSnapshotInMemory(for: server.id), !snap.libraryViews.isEmpty {
            performBatchedHomeShelfUpdate {
                activeServerId = server.id
                openedServerId = server.id
                applyHomeSnapshot(snap, for: server)
            }
            if !ServerHomeCacheStore.shared.isSnapshotFresh(for: server.id) {
                Task { await loadActiveServerHome(syncDomains: true, forceRefresh: false) }
            }
        } else {
            performBatchedHomeShelfUpdate {
                activeServerId = server.id
                openedServerId = server.id
                self.libraryViews = []
                self.resumeItems = []
                self.nextUpItems = []
                self.favoriteItems = []
                self.latestByLibrary = [:]
            }
            self.carouselItems = []
            let hasHost = !server.host.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            self.isLoadingHome = hasHost
            let targetServer = server
            Task { [weak self] in
                let snap = await ServerHomeCacheStore.shared.loadSnapshotFromDiskAsync(for: targetServer.id)
                await MainActor.run {
                    guard let self, self.openedServerId == targetServer.id else { return }
                    if let snap, !snap.libraryViews.isEmpty {
                        if self.libraryViews.isEmpty {
                            self.applyHomeSnapshot(snap, for: targetServer)
                        }
                        if !ServerHomeCacheStore.shared.isSnapshotFresh(for: targetServer.id) {
                            Task { await self.loadActiveServerHome(syncDomains: true, forceRefresh: false) }
                        }
                    } else if hasHost {
                        Task { await self.loadActiveServerHome(syncDomains: true, forceRefresh: false) }
                    }
                }
            }
        }

        PlaybackIntentCoordinator.shared.warmServerOnConnectOrLaunch(server: server)
    }

    func applyHomeSnapshot(_ snap: ServerHomeCacheStore.ServerHomeSnapshot, for server: EmbyServerConfig) {
        homeCurationGeneration &+= 1
        let curationGeneration = homeCurationGeneration
        let targetServerId = server.id

        performBatchedHomeShelfUpdate {
            if self.libraryViews != snap.libraryViews { self.libraryViews = snap.libraryViews }
            if self.resumeItems != snap.resumeItems { self.resumeItems = snap.resumeItems }
            if self.nextUpItems != snap.nextUpItems { self.nextUpItems = snap.nextUpItems }
            if self.favoriteItems != snap.favoriteItems { self.favoriteItems = snap.favoriteItems }
            if self.latestByLibrary != snap.latestByLibrary { self.latestByLibrary = snap.latestByLibrary }
        }
        if self.carouselItems != snap.carouselItems {
            self.carouselItems = snap.carouselItems
        }
        self.isLoadingHome = false

        let explicitAnime = DonbyAppExtensionCenter.shared.plugin?.isAnimeModeActive(for: server)
        let serverName = server.name
        let shouldRecurate = snap.carouselItems.isEmpty && !snap.latestByLibrary.isEmpty
        let initialCarousel = snap.carouselItems

        Task.detached(priority: .userInitiated) { [weak self] in
            let nextCarousel: [EmbyItem]
            if shouldRecurate {
                nextCarousel = HomeHeroCurator.selectHeroItems(
                    libraryViews: snap.libraryViews,
                    latestByLibrary: snap.latestByLibrary,
                    fallbackResumes: snap.resumeItems,
                    serverName: serverName,
                    explicitAnimeMode: explicitAnime
                )
            } else {
                nextCarousel = initialCarousel
            }
            let cached = await MultiPlatformRatingService.shared.cachedRatingsByItemId(for: nextCarousel)
            if let firstHero = nextCarousel.first,
               MediaArtworkView.cachedCGImageInMemory(item: firstHero, kind: .backdrop, maxWidth: 2200) == nil {
                _ = await MediaArtworkView.loadOrFetchCGImage(
                    server: server,
                    item: firstHero,
                    kind: .backdrop,
                    maxWidth: 2200,
                    priority: .high
                )
            }
            await MainActor.run {
                guard let self,
                      self.homeCurationGeneration == curationGeneration,
                      self.openedServerId == targetServerId else { return }
                if shouldRecurate && self.carouselItems != nextCarousel {
                    self.carouselItems = nextCarousel
                }
                if !cached.isEmpty {
                    self.mergeRatingsBatch(cached)
                }
            }
        }
    }

    public func selectSidebarModule(_ tab: MainNavigationTab) {
        cancelPendingPlaybackStart()
        homeCurationGeneration &+= 1
        openedServerId = nil
        selectedLibrary = nil
        detailStack.removeAll()
        detailOfflineFocusIds.removeAll()
        detailFocusedEpisodeMemory.removeAll()
        selectedTab = tab

        if tab == .files {
            if !defaultFilesFolderId.isEmpty, let folder = localFolders.first(where: { $0.id.uuidString == defaultFilesFolderId }) {
                browsingFolder = folder
            } else {
                browsingFolder = nil
            }
        }
    }
}

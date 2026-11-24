import Foundation
import Testing
@testable import DonbyCore
@testable import DonbyNetwork
#if canImport(DonbyUHDModule) && !DONBY_PURE_BUILD
@testable import DonbyUHDModule
#endif

@Suite("UHD & Artwork Integration Tests", .serialized)
struct UHDAndArtworkIntegrationTests {
    #if canImport(DonbyUHDModule) && !DONBY_PURE_BUILD
    @Test func uhdSpeedTestMetricsEngineWarmupAndRollingPeakAndShortFallback() {
        // 1. Steady 100 Mbps stream (12.5 MB/s) after warmup >= 300ms & > 1 MiB
        var engine = UHDSpeedTestMetricsEngine(startTimeSec: 10.0)
        let bytesPerStep: Int64 = 1_250_000 // 1.25 MB every 0.1s = 100 Mbps
        for step in 1...20 {
            let t = 10.0 + Double(step) * 0.10
            engine.ingest(chunkBytes: bytesPerStep, at: t)
        }
        let snap = engine.finalize(at: 12.0)
        #expect(snap.totalBytes == 25_000_000)
        #expect(snap.elapsedMs == 2000)
        #expect(snap.sampleCount >= 10)
        #expect(abs(snap.averageMbps - 100.0) < 5.0)
        #expect(snap.peakMbps >= snap.averageMbps)
        #expect(snap.peakMbps <= 5000.0)

        // 2. Short test fallback (finishes before warmup completes -> uses total bytes / max(250ms, elapsed) with 1 sample)
        var shortEngine = UHDSpeedTestMetricsEngine(startTimeSec: 5.0)
        shortEngine.ingest(chunkBytes: 500_000, at: 5.10)
        let shortSnap = shortEngine.finalize(at: 5.10)
        #expect(shortSnap.sampleCount == 1)
        #expect(shortSnap.totalBytes == 500_000)
        // 500_000 * 8 / 0.25 / 1_000_000 = 16.0 Mbps
        #expect(abs(shortSnap.averageMbps - 16.0) < 0.01)
    }

    @Test func uhdParsersAndRatingAndWatchPartyExtrapolation() throws {
        // Login code normalizer preserves leading zeros and strips grouping spaces
        #expect(UHDLoginCodeNormalizer.normalize("0428 1753") == "04281753")
        #expect(UHDLoginCodeNormalizer.normalize("0428-1753") == "04281753")
        #expect(UHDLoginCodeNormalizer.normalize("1234567") == nil)
        #expect(UHDLoginCodeNormalizer.formattedDisplay("04281753") == "0428 1753")

        // Watch Party invite extractor (raw code & shared URL)
        #expect(UHDWatchPartyInviteParser.extractInviteCode(from: "0428 1736") == "04281736")
        #expect(UHDWatchPartyInviteParser.extractInviteCode(from: "https://media.example.com/stream/play?invite=04281736") == "04281736")
        #expect(UHDWatchPartyInviteParser.extractInviteCode(from: "not-an-invite") == nil)

        // TMDB search query parser
        let p1 = UHDTmdbSearchQueryParser.parse("tmdb:1399")
        #expect(p1?.tmdbId == 1399 && p1?.mediaType == nil)
        let p2 = UHDTmdbSearchQueryParser.parse("tmdb:tv:1399")
        #expect(p2?.tmdbId == 1399 && p2?.mediaType == "tv")
        let p3 = UHDTmdbSearchQueryParser.parse("https://www.themoviedb.org/movie/603")
        #expect(p3?.tmdbId == 603 && p3?.mediaType == "movie")
        #expect(UHDTmdbSearchQueryParser.parse("权力的游戏") == nil)

        // Rating 10x integer normalization
        #expect(UHDRatingNormalizer.normalize(85) == 8.5)
        #expect(UHDRatingNormalizer.normalize(0) == nil)
        #expect(UHDRatingNormalizer.normalize(7.8) == 7.8)

        // Watch Party extrapolated position (playing vs paused)
        let playingSnap = UHDWatchPartyRoomSnapshot(
            id: "room-1",
            invite: "04281736",
            hostId: "u1",
            maxMembers: 4,
            locked: false,
            members: [],
            media: UHDWatchPartyMedia(itemType: "movie", itemId: "m1", assetId: "a1"),
            phase: "playing",
            positionMs: 120_000,
            serverMs: 1_000_000,
            rate: 1.5,
            intent: true,
            control: "play",
            epoch: 1,
            term: 1,
            revision: 2
        )
        // +4 seconds elapsed * 1.5x = +6s -> 126.0s
        #expect(abs(playingSnap.extrapolatedPositionSeconds(estimatedServerNowMs: 1_004_000) - 126.0) < 0.001)

        let pausedSnap = UHDWatchPartyRoomSnapshot(
            id: "room-1",
            invite: "04281736",
            hostId: "u1",
            maxMembers: 4,
            locked: false,
            members: [],
            media: UHDWatchPartyMedia(itemType: "movie", itemId: "m1", assetId: "a1"),
            phase: "paused",
            positionMs: 120_000,
            serverMs: 1_000_000,
            rate: 1.5,
            intent: false,
            control: "pause",
            epoch: 1,
            term: 1,
            revision: 3
        )
        // Paused never extrapolates forward
        #expect(abs(pausedSnap.extrapolatedPositionSeconds(estimatedServerNowMs: 1_010_000) - 120.0) < 0.001)
    }

    @Test func uhdModuleEndpointsSmartToV1FallbackAndChinaOptimizedSelection() {
        // Default zero-URL order must try China-optimized smart.uhdnow.com first, then v1.uhdnow.com
        let defaults = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: nil)
        #expect(defaults == ["https://smart.uhdnow.com", "https://v1.uhdnow.com"])

        let blankCustom = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: "   ")
        #expect(blankCustom == ["https://smart.uhdnow.com", "https://v1.uhdnow.com"])

        let custom = UHDModuleEndpoints.candidateBaseURLs(customBaseURL: "custom.example.com/")
        #expect(custom == ["https://custom.example.com"])

        // Fallback policy: password/token fall back on 403/404/401/5xx/network; loginCode preserves 401
        #expect(UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: EmbyClientError.httpStatus(403, "no plan"), authKind: .password))
        #expect(UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: EmbyClientError.unauthorized, authKind: .password))
        #expect(UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: URLError(.timedOut), authKind: .password))
        #expect(!UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: CancellationError(), authKind: .password))
        #expect(UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: EmbyClientError.httpStatus(403, "no plan"), authKind: .loginCode))
        #expect(!UHDModuleEndpoints.shouldFallbackToStandardEndpoint(after: EmbyClientError.unauthorized, authKind: .loginCode))

        // China-optimized playback line auto-selection
        let globalLine = ServerLineInfo(name: "Global Proxy", url: "https://v1.uhdnow.com", domainId: "d1", isAutoSynced: true)
        let chinaLine = ServerLineInfo(name: "中国大陆优化直连", url: "https://cn.uhdnow.online", domainId: "d2", isAutoSynced: true)
        let pickedForSmart = UHDModuleEndpoints.pickPreferredDefaultLine(
            from: [globalLine, chinaLine],
            loggedInBaseURL: "https://smart.uhdnow.com"
        )
        #expect(pickedForSmart?.id == chinaLine.id)

        // Standard account without China-optimized line falls back to first line
        let standardLine2 = ServerLineInfo(name: "Backup Proxy", url: "https://v1-vod1.uhdnow.com", domainId: "d3", isAutoSynced: true)
        let pickedForStandard = UHDModuleEndpoints.pickPreferredDefaultLine(
            from: [globalLine, standardLine2],
            loggedInBaseURL: "https://v1.uhdnow.com"
        )
        #expect(pickedForStandard?.id == globalLine.id)
    }

    @Test func uhdModuleInstallUninstallRegistryIsolation() {
        DonbyUHDModule.uninstall()
        #expect(!DonbyUHDModule.isInstalled)
        #expect(DonbyMediaServiceRegistry.shared.provider(for: .uhdNative) == nil)

        DonbyUHDModule.install()
        #expect(DonbyUHDModule.isInstalled)
        #expect(DonbyMediaServiceRegistry.shared.provider(for: .uhdNative) != nil)

        DonbyUHDModule.uninstall()
        #expect(!DonbyUHDModule.isInstalled)
    }

    @Test func uhdDisplayNormalizerStripsVerboseLineDescriptionsAndNormalizesExitCopy() {
        let cnLine = ServerLineInfo(
            name: "中国大陆优化 · 智能调配的中国大陆三网优化 CDN",
            url: "https://smart.uhdnow.com/"
        )
        #expect(cnLine.cleanDisplayName == "中国大陆 CDN")
        #expect(cnLine.cleanDisplayHost == "smart.uhdnow.com")

        let cfProLine = ServerLineInfo(
            name: "国际方向 · CloudFlare Pro CDN 提供的优质海外线路",
            url: "https://v1.uhdnow.com"
        )
        #expect(cfProLine.cleanDisplayName == "Cloudflare Pro CDN")
        #expect(cfProLine.cleanDisplayHost == "v1.uhdnow.com")

        let cfBackupLine = ServerLineInfo(name: "国际方向-备用", url: "https://v1.uhdgo.com")
        #expect(cfBackupLine.cleanDisplayName == "Cloudflare CDN")
        #expect(cfBackupLine.cleanDisplayHost == "v1.uhdgo.com")

        let genericLine = ServerLineInfo(name: "香港节点 · 极速专线", url: "https://emby.example.com")
        #expect(genericLine.cleanDisplayName == "香港节点")

        #expect(UHDDisplayNormalizer.formatCDNLineName(rawName: "国际方向", description: "CloudFlare Pro CDN", url: "https://v1.uhdnow.com") == "Cloudflare Pro CDN")
        #expect(UHDDisplayNormalizer.formatCDNLineName(rawName: "国际方向-备用", description: "国际主线路不稳定时可使用", url: "https://v1.uhdgo.com") == "Cloudflare CDN")
        #expect(UHDDisplayNormalizer.formatCDNLineName(rawName: "中国大陆优化", description: "三网优化 CDN", url: "https://smart.uhdnow.com") == "中国大陆 CDN")

        #expect(UHDDisplayNormalizer.formatPlanName("China 优化版") == "中国优化版")
        #expect(UHDDisplayNormalizer.formatExitBadge(location: "陕西省", isp: "cmcc") == "陕西 · 中国移动")
        #expect(UHDDisplayNormalizer.formatExitBadge(location: "GB / 欧洲", isp: "") == "英国")
        #expect(UHDDisplayNormalizer.formatExitBadge(location: "广东省", isp: "ctcc") == "广东 · 中国电信")
    }
    #endif

    @Test func embyClientDualModeEpisodeArtworkAndUHDTokenIsolation() {
        let bareEpisodeULID = "0189ABCD1234567890ABCDEF12" // 26 chars starting with "01"
        let bareSeriesULID = "0189ABCD1234567890ABCDEF99"
        let uhdServer = EmbyServerConfig(
            name: "UHD Test",
            type: .uhdNative,
            host: "uhd.example.com",
            username: "tester",
            accessToken: "jwt-uhd-secret"
        )

        #if canImport(DonbyUHDModule) && !DONBY_PURE_BUILD
        let wasInstalled = DonbyUHDModule.isInstalled
        defer {
            if wasInstalled {
                DonbyUHDModule.install()
            } else {
                DonbyUHDModule.uninstall()
            }
        }

        DonbyUHDModule.install()
        // When UHD extension is active, itemId-based /emby/Items/... URLs must return nil (prevents 401/404 storms and token leak)
        #expect(EmbyClient.shared.imageURL(server: uhdServer, itemId: bareEpisodeULID, kind: .primary, maxWidth: 560) == nil)
        #expect(EmbyClient.shared.imageURL(server: uhdServer, itemId: bareEpisodeULID, kind: .thumb, maxWidth: 560) == nil)
        #expect(EmbyClient.shared.imageURL(server: uhdServer, itemId: bareSeriesULID, kind: .logo, maxWidth: 800) == nil)

        // Episode with only thumb_url must resolve across .thumb, .primary, and .backdrop
        let epThumbOnly = EmbyItem(
            id: bareEpisodeULID,
            name: "Episode 1",
            type: "Episode",
            seriesId: bareSeriesULID,
            uhdThumbURL: "https://uhd.example.com/img/ep1-thumb.jpg",
            uhdMediaType: "episode"
        )
        #expect(EmbyClient.shared.imageURL(server: uhdServer, item: epThumbOnly, kind: .thumb)?.absoluteString == "https://uhd.example.com/img/ep1-thumb.jpg")
        #expect(EmbyClient.shared.imageURL(server: uhdServer, item: epThumbOnly, kind: .primary)?.absoluteString == "https://uhd.example.com/img/ep1-thumb.jpg")
        #expect(EmbyClient.shared.imageURL(server: uhdServer, item: epThumbOnly, kind: .backdrop)?.absoluteString == "https://uhd.example.com/img/ep1-thumb.jpg")

        // Unscraped episode missing thumb_url inherits season poster, series fanart, and logo cleanly
        let epUnscraped = EmbyItem(
            id: "0189ABCD1234567890ABCDEF13",
            name: "Episode 2",
            type: "Episode",
            seriesId: bareSeriesULID,
            uhdMediaType: "episode"
        ).withInheritedArtworkFallback(
            posterURL: "https://uhd.example.com/img/season1.jpg",
            backdropURL: "https://uhd.example.com/img/series-fanart.jpg",
            logoURL: "https://uhd.example.com/img/series-logo.png"
        )
        #expect(EmbyClient.shared.imageURL(server: uhdServer, item: epUnscraped, kind: .thumb)?.absoluteString == "https://uhd.example.com/img/series-fanart.jpg")
        #expect(EmbyClient.shared.imageURL(server: uhdServer, item: epUnscraped, kind: .primary)?.absoluteString == "https://uhd.example.com/img/season1.jpg")
        #expect(EmbyClient.shared.imageURL(server: uhdServer, item: epUnscraped, kind: .backdrop)?.absoluteString == "https://uhd.example.com/img/series-fanart.jpg")
        #expect(EmbyClient.shared.imageURL(server: uhdServer, item: epUnscraped, kind: .logo)?.absoluteString == "https://uhd.example.com/img/series-logo.png")

        DonbyUHDModule.uninstall()
        #endif

        // Standard Emby fallback (both when UHD module is uninstalled and in DONBY_PURE=1 builds)
        let embyFallbackURL = EmbyClient.shared.imageURL(server: uhdServer, itemId: bareEpisodeULID, kind: .primary, maxWidth: 560)?.absoluteString
        #expect(embyFallbackURL?.contains("/emby/Items/\(bareEpisodeULID)/Images/Primary") == true)

        let epEmbyFallback = EmbyItem(
            id: bareEpisodeULID,
            name: "Episode 1",
            type: "Episode",
            seriesId: "s\(bareSeriesULID)",
            imageTags: ["Primary": "tag123"]
        )
        let epThumbFallbackURL = EmbyClient.shared.imageURL(server: uhdServer, item: epEmbyFallback, kind: .thumb, maxWidth: 560)?.absoluteString
        #expect(epThumbFallbackURL?.contains("/emby/Items/e\(bareEpisodeULID)/Images/Primary") == true)
    }
}

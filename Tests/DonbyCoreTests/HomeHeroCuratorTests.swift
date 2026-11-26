import Foundation
import Testing
@testable import DonbyCore

@Suite("HomeHeroCuratorTests")
struct HomeHeroCuratorTests {

    private func makeItem(
        id: String,
        name: String,
        originalTitle: String? = nil,
        type: String = "Movie",
        genres: [String]? = nil,
        communityRating: Double? = nil,
        criticRating: Double? = nil,
        productionYear: Int? = nil,
        runTimeTicks: Int64? = nil,
        childCount: Int? = nil,
        overview: String? = "A compelling synopsis with enough length to pass visual polish checks.",
        hasBackdrop: Bool = true,
        hasLogo: Bool = false,
        studios: [EmbyNameIdPair]? = nil
    ) -> EmbyItem {
        EmbyItem(
            id: id,
            name: name,
            originalTitle: originalTitle,
            type: type,
            overview: overview,
            genres: genres,
            communityRating: communityRating,
            criticRating: criticRating,
            productionYear: productionYear,
            runTimeTicks: runTimeTicks,
            childCount: childCount,
            imageTags: ["Primary": "p1"],
            backdropImageTags: hasBackdrop ? ["b1"] : nil,
            studios: studios,
            uhdLogoURL: hasLogo ? "https://example.com/logo.png" : nil
        )
    }

    @Test("Classic movies and foreign series strongly outrank domestic web dramas")
    func classicMoviesAndForeignSeriesOutrankDomesticWebDramas() {
        let classicMovie = makeItem(
            id: "m_classic",
            name: "肖申克的救赎",
            originalTitle: "The Shawshank Redemption",
            type: "Movie",
            genres: ["剧情", "犯罪"],
            communityRating: 9.3,
            criticRating: 91,
            productionYear: 1994
        )
        let foreignSeries = makeItem(
            id: "s_foreign",
            name: "绝命毒师",
            originalTitle: "Breaking Bad",
            type: "Series",
            genres: ["犯罪", "剧情"],
            communityRating: 8.9,
            productionYear: 2008,
            childCount: 5
        )
        let cheapWebDrama = makeItem(
            id: "s_cheap",
            name: "闪婚后霸总把我宠上天",
            originalTitle: "闪婚后霸总把我宠上天",
            type: "Series",
            genres: ["甜宠", "都市", "爱情"],
            communityRating: 5.1,
            productionYear: 2025,
            runTimeTicks: 8 * 60 * 10_000_000,
            childCount: 1
        )
        let unratedDomestic = makeItem(
            id: "s_unrated",
            name: "某流量仙侠古偶剧",
            originalTitle: nil,
            type: "Series",
            genres: ["仙侠", "爱情"],
            communityRating: nil,
            productionYear: 2025,
            childCount: 1
        )

        let classicAudit = HomeHeroCurator.audit(classicMovie, libraryName: "电影", referenceYear: 2026)
        let foreignAudit = HomeHeroCurator.audit(foreignSeries, libraryName: "欧美剧", referenceYear: 2026)
        let cheapAudit = HomeHeroCurator.audit(cheapWebDrama, libraryName: "国产剧", referenceYear: 2026)
        let unratedAudit = HomeHeroCurator.audit(unratedDomestic, libraryName: "国产剧", referenceYear: 2026)

        #expect(classicAudit.isClassicMovie)
        #expect(classicAudit.isForeignMovie)
        #expect(!classicAudit.isCheapDomesticWebDrama)

        #expect(foreignAudit.isForeignSeries)
        #expect(!foreignAudit.isCheapDomesticWebDrama)

        #expect(cheapAudit.isDomesticSeries)
        #expect(cheapAudit.isCheapDomesticWebDrama)
        #expect(cheapAudit.score < 0)

        #expect(unratedAudit.isDomesticSeries)
        #expect(unratedAudit.isCheapDomesticWebDrama)
        #expect(unratedAudit.score < 0)

        #expect(classicAudit.score > cheapAudit.score + 100)
        #expect(foreignAudit.score > unratedAudit.score + 80)
    }

    @Test("Japanese and Korean series with Kana/Hangul originalTitle are recognized as foreign series")
    func jpKrOriginalTitlesDetectedAsForeign() {
        let jdrama = makeItem(
            id: "s_jp",
            name: "重启人生",
            originalTitle: "ブラッシュアップライフ",
            type: "Series",
            genres: ["剧情", "喜剧"],
            communityRating: 8.6,
            productionYear: 2023
        )
        let kdrama = makeItem(
            id: "s_kr",
            name: "秘密森林",
            originalTitle: "비밀의 숲",
            type: "Series",
            genres: ["悬疑", "犯罪"],
            communityRating: 8.5,
            productionYear: 2017,
            childCount: 2
        )

        let jpAudit = HomeHeroCurator.audit(jdrama, libraryName: "剧集", referenceYear: 2026)
        let krAudit = HomeHeroCurator.audit(kdrama, libraryName: "剧集", referenceYear: 2026)

        #expect(jpAudit.isForeignSeries)
        #expect(!jpAudit.isCheapDomesticWebDrama)
        #expect(krAudit.isForeignSeries)
        #expect(!krAudit.isCheapDomesticWebDrama)
    }

    @Test("selectHeroItems filters out cheap domestic web dramas and promotes classics/foreign series")
    func selectHeroItemsFiltersCheapDramasAndPromotesClassics() {
        let views = [
            EmbyItem(id: "lib_cn", name: "国产剧", type: "CollectionFolder"),
            EmbyItem(id: "lib_movies", name: "电影", type: "CollectionFolder"),
            EmbyItem(id: "lib_us", name: "欧美剧", type: "CollectionFolder")
        ]

        let cheap1 = makeItem(id: "c1", name: "重生之龙王赘婿归来", type: "Series", genres: ["短剧"], communityRating: nil, productionYear: 2026)
        let cheap2 = makeItem(id: "c2", name: "替嫁娇妻总裁偏宠我", type: "Series", genres: ["甜宠"], communityRating: 4.8, productionYear: 2025)
        let mediocreCN = makeItem(id: "c3", name: "普通都市言情剧", type: "Series", genres: ["都市", "爱情"], communityRating: 6.2, productionYear: 2025)

        let classic1 = makeItem(id: "m1", name: "教父", originalTitle: "The Godfather", type: "Movie", genres: ["犯罪", "剧情"], communityRating: 9.2, productionYear: 1972)
        let classic2 = makeItem(id: "m2", name: "星际穿越", originalTitle: "Interstellar", type: "Movie", genres: ["科幻", "冒险"], communityRating: 8.7, productionYear: 2014)
        let foreign1 = makeItem(id: "f1", name: "真探", originalTitle: "True Detective", type: "Series", genres: ["犯罪", "悬疑"], communityRating: 8.5, productionYear: 2014, childCount: 4)
        let foreign2 = makeItem(id: "f2", name: "切尔诺贝利", originalTitle: "Chernobyl", type: "Series", genres: ["历史", "剧情"], communityRating: 9.1, productionYear: 2019)

        let selected = HomeHeroCurator.selectHeroItems(
            libraryViews: views,
            latestByLibrary: [
                "lib_cn": [cheap1, cheap2, mediocreCN],
                "lib_movies": [classic1, classic2],
                "lib_us": [foreign1, foreign2]
            ],
            maxCount: 8,
            referenceYear: 2026
        )

        let selectedIds = selected.map(\.id)
        #expect(selectedIds.count == 4)
        #expect(selectedIds.contains("m1"))
        #expect(selectedIds.contains("m2"))
        #expect(selectedIds.contains("f1"))
        #expect(selectedIds.contains("f2"))
        #expect(!selectedIds.contains("c1"))
        #expect(!selectedIds.contains("c2"))
        #expect(!selectedIds.contains("c3"))
    }

    @Test("Acclaimed domestic masterpiece is not falsely flagged as cheap web drama")
    func acclaimedDomesticMasterpiecePassesAudit() {
        let masterpiece = makeItem(
            id: "cn_masterpiece",
            name: "漫长的季节",
            originalTitle: "漫长的季节",
            type: "Series",
            genres: ["剧情", "悬疑", "犯罪"],
            communityRating: 8.9,
            productionYear: 2023,
            runTimeTicks: 60 * 60 * 10_000_000,
            hasBackdrop: true
        )

        let audit = HomeHeroCurator.audit(masterpiece, libraryName: "国产剧", referenceYear: 2026)
        #expect(audit.isDomesticSeries)
        #expect(!audit.isCheapDomesticWebDrama)
        #expect(audit.score > 0)

        let imdbVerified = MultiPlatformRatings(tmdb: 8.9, imdb: 8.5, imdbVotes: 6500)
        let verifiedAudit = HomeHeroCurator.audit(masterpiece, libraryName: "国产剧", referenceYear: 2026, multiPlatformRatings: imdbVerified)
        #expect(!verifiedAudit.isCheapDomesticWebDrama)
        #expect(verifiedAudit.score > 30)
    }

    @Test("Deduplicates identical title+year across libraries keeping highest-scored backdrop entry")
    func deduplicatesAcrossLibrariesKeepingBestArtwork() {
        let views = [
            EmbyItem(id: "lib_a", name: "最新电影", type: "CollectionFolder"),
            EmbyItem(id: "lib_b", name: "经典电影", type: "CollectionFolder")
        ]
        let noBackdrop = makeItem(id: "dup_1", name: "盗梦空间", originalTitle: "Inception", type: "Movie", communityRating: 8.8, productionYear: 2010, hasBackdrop: false)
        let withBackdrop = makeItem(id: "dup_2", name: "盗梦空间", originalTitle: "Inception", type: "Movie", communityRating: 8.8, productionYear: 2010, hasBackdrop: true)

        let selected = HomeHeroCurator.selectHeroItems(
            libraryViews: views,
            latestByLibrary: [
                "lib_a": [noBackdrop],
                "lib_b": [withBackdrop]
            ],
            maxCount: 8,
            referenceYear: 2026
        )

        #expect(selected.count == 1)
        #expect(selected.first?.id == "dup_2")
    }

    @Test("Hot recent foreign series receive strong boost and rank alongside classics")
    func hotRecentForeignSeriesReceiveStrongBoost() {
        let hotNewForeign = makeItem(
            id: "s_hot_new",
            name: "人生切割术",
            originalTitle: "Severance",
            type: "Series",
            genres: ["科幻", "悬疑", "剧情"],
            communityRating: 8.4,
            productionYear: 2025,
            childCount: 2
        )
        let newlyAiringForeign = makeItem(
            id: "s_airing_new",
            name: "新晋热门美剧",
            originalTitle: "The Pitt",
            type: "Series",
            genres: ["剧情"],
            communityRating: nil,
            productionYear: 2026
        )
        let ordinaryMovie = makeItem(
            id: "m_ordinary",
            name: "普通新电影",
            originalTitle: "Ordinary Film",
            type: "Movie",
            genres: ["动作"],
            communityRating: 6.6,
            productionYear: 2025
        )

        let hotAudit = HomeHeroCurator.audit(hotNewForeign, libraryName: "欧美剧", referenceYear: 2026, libraryRank: 0)
        let airingAudit = HomeHeroCurator.audit(newlyAiringForeign, libraryName: "欧美剧", referenceYear: 2026, libraryRank: 1)
        let ordinaryAudit = HomeHeroCurator.audit(ordinaryMovie, libraryName: "电影", referenceYear: 2026, libraryRank: 0)

        #expect(hotAudit.isForeignSeries)
        #expect(airingAudit.isForeignSeries)
        #expect(hotAudit.score > ordinaryAudit.score + 40)
        #expect(airingAudit.score > ordinaryAudit.score)
    }

    @Test("Six-platform consensus outweighs noisy single-platform TMDB rating")
    func multiPlatformConsensusOutweighsSinglePlatformTMDB() {
        // Matches 6-platform profile: TMDB 6.9, IMDb 7.2, RT 90%, Popcorn 83%, Trakt 67%, Metacritic 81
        let acclaimedFilm = makeItem(
            id: "m_6plat",
            name: "口碑佳作",
            originalTitle: "Acclaimed Feature",
            type: "Movie",
            genres: ["剧情", "惊悚"],
            communityRating: 6.9,
            productionYear: 2024
        )
        let sixPlatformRatings = MultiPlatformRatings(
            tmdb: 6.9,
            tmdbVotes: 1800,
            imdb: 7.2,
            imdbVotes: 85_000,
            rottenTomatoesCritics: 90,
            rottenTomatoesAudience: 83,
            trakt: 67,
            traktVotes: 4200,
            metacritic: 81
        )

        // Single-platform TMDB-only item with inflated score from tiny vote count and zero IMDb/RT/Metacritic
        let inflatedTMDBOnly = makeItem(
            id: "m_tmdb_only",
            name: "冷门刷分片",
            originalTitle: "Obscure Inflated Film",
            type: "Movie",
            genres: ["剧情"],
            communityRating: 8.6,
            productionYear: 2024
        )
        let tmdbOnlyRatings = MultiPlatformRatings(
            tmdb: 8.6,
            tmdbVotes: 8
        )

        let eval6 = MultiPlatformRatings.evaluate(sixPlatformRatings, fallbackTMDB: 6.9, fallbackCriticRating: nil)
        let eval1 = MultiPlatformRatings.evaluate(tmdbOnlyRatings, fallbackTMDB: 8.6, fallbackCriticRating: nil)

        #expect(eval6.authoritativePlatformCount == 5)
        #expect(eval6.isStrongConsensus)
        #expect(eval1.authoritativePlatformCount == 0)
        #expect((eval6.weightedScore ?? 0) > (eval1.weightedScore ?? 0))

        let audit6 = HomeHeroCurator.audit(acclaimedFilm, libraryName: "电影", referenceYear: 2026, multiPlatformRatings: sixPlatformRatings)
        let audit1 = HomeHeroCurator.audit(inflatedTMDBOnly, libraryName: "电影", referenceYear: 2026, multiPlatformRatings: tmdbOnlyRatings)

        #expect(audit6.score > audit1.score + 40)
    }

    @Test("Extra top-rated candidate pool rescues hero carousel when latest shelf is low quality")
    func extraTopRatedPoolRescuesLowQualityLatestShelf() {
        let views = [EmbyItem(id: "lib_m", name: "电影", type: "CollectionFolder")]
        let pannedLatest = makeItem(
            id: "m_bad",
            name: "烂片新上架",
            originalTitle: "Bad Recent Movie",
            type: "Movie",
            communityRating: 5.4,
            productionYear: 2026
        )
        let classicExtra = makeItem(
            id: "m_classic_extra",
            name: "蝙蝠侠：黑暗骑士",
            originalTitle: "The Dark Knight",
            type: "Movie",
            genres: ["动作", "犯罪", "剧情"],
            communityRating: 8.5,
            criticRating: 94,
            productionYear: 2008
        )
        let ratings: [String: MultiPlatformRatings] = [
            "m_bad": MultiPlatformRatings(tmdb: 5.4, imdb: 5.2, imdbVotes: 3000, rottenTomatoesCritics: 28, metacritic: 39),
            "m_classic_extra": MultiPlatformRatings(tmdb: 8.5, imdb: 9.0, imdbVotes: 2_900_000, rottenTomatoesCritics: 94, rottenTomatoesAudience: 94, trakt: 86, metacritic: 84)
        ]

        let selected = HomeHeroCurator.selectHeroItems(
            libraryViews: views,
            latestByLibrary: ["lib_m": [pannedLatest]],
            extraCandidates: [classicExtra],
            ratingsByItemId: ratings,
            maxCount: 8,
            referenceYear: 2026
        )

        #expect(selected.first?.id == "m_classic_extra")
    }
}

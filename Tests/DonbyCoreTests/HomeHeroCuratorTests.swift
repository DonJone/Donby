import Foundation
import Testing
import zlib
@testable import DonbyCore
@testable import DonbyNetwork

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

    @Test("Japanese series are foreign tier while Korean series route to dedicated Korean scrutiny tier")
    func jpKrOriginalTitlesDetectedByRegion() {
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
        #expect(krAudit.isKoreanSeries)
        #expect(!krAudit.isIdolOrBLFiltered)
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
        #expect(verifiedAudit.score > 20)
        #expect(verifiedAudit.score > audit.score + 15)
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

    @Test("Unverified 10.0 / 9.8 perfect ratings are flagged suspicious and lose to verified classics")
    func unverifiedPerfectRatingsFlaggedAndPenalized() {
        let fakePerfectMovie = makeItem(
            id: "m_fake_10",
            name: "冷门满分刷分片",
            originalTitle: "Obscure Perfect 10",
            type: "Movie",
            genres: ["剧情"],
            communityRating: 10.0,
            productionYear: 2025
        )
        let lowVoteBrigaded = makeItem(
            id: "s_brigaded",
            name: "开播刷分剧",
            originalTitle: "Brigaded Launch Show",
            type: "Series",
            genres: ["剧情"],
            communityRating: 9.7,
            productionYear: 2026
        )
        let verifiedClassic = makeItem(
            id: "m_verified",
            name: "奥本海默",
            originalTitle: "Oppenheimer",
            type: "Movie",
            genres: ["剧情", "历史"],
            communityRating: 8.1,
            criticRating: 93,
            productionYear: 2023
        )
        let verifiedSeries = makeItem(
            id: "s_breaking_bad",
            name: "绝命毒师",
            originalTitle: "Breaking Bad",
            type: "Series",
            genres: ["犯罪", "剧情"],
            communityRating: 8.9,
            criticRating: 96,
            productionYear: 2008,
            childCount: 5
        )

        let fakeAudit = HomeHeroCurator.audit(fakePerfectMovie, libraryName: "电影", referenceYear: 2026)
        let brigadedMP = MultiPlatformRatings(tmdb: 9.7, tmdbVotes: 25, imdb: 9.7, imdbVotes: 120)
        let brigadedAudit = HomeHeroCurator.audit(lowVoteBrigaded, libraryName: "欧美剧", referenceYear: 2026, multiPlatformRatings: brigadedMP)
        let verifiedMP = MultiPlatformRatings(tmdb: 8.1, tmdbVotes: 9200, imdb: 8.3, imdbVotes: 850_000, rottenTomatoesCritics: 93, rottenTomatoesAudience: 91, metacritic: 90)
        let verifiedAudit = HomeHeroCurator.audit(verifiedClassic, libraryName: "电影", referenceYear: 2026, multiPlatformRatings: verifiedMP)
        let bbMP = MultiPlatformRatings(tmdb: 8.9, tmdbVotes: 14_000, imdb: 9.5, imdbVotes: 2_300_000, rottenTomatoesCritics: 96, rottenTomatoesAudience: 97, metacritic: 87)
        let bbAudit = HomeHeroCurator.audit(verifiedSeries, libraryName: "欧美剧", referenceYear: 2026, multiPlatformRatings: bbMP)

        #expect(fakeAudit.isSuspiciousPerfectRating)
        #expect(fakeAudit.effectiveRating < 7.0)
        #expect(brigadedAudit.isSuspiciousPerfectRating)
        #expect(!verifiedAudit.isSuspiciousPerfectRating)
        #expect(!bbAudit.isSuspiciousPerfectRating)
        #expect(verifiedAudit.score > fakeAudit.score + 70)
        #expect(bbAudit.score > brigadedAudit.score + 70)
    }

    @Test("Fan-brigaded audience-vs-critic divergence is penalized as inflated")
    func audienceVsCriticDivergencePenalized() {
        let brigadedMP = MultiPlatformRatings(
            tmdb: 9.1,
            tmdbVotes: 800,
            imdb: 7.1,
            imdbVotes: 12_000,
            rottenTomatoesCritics: 46,
            rottenTomatoesAudience: 94,
            metacritic: 51
        )
        let eval = MultiPlatformRatings.evaluate(brigadedMP, fallbackTMDB: 9.1, fallbackCriticRating: 46, isMovie: true)
        #expect(eval.isRatingInflated)
        #expect(eval.consensusDelta < 0)
    }

    @Test("Non-anime servers and UHD Normal Hall exclude anime from hero; Anime Hall/server allows it with deflation")
    func animeExclusionOnNonAnimeHomeAndNormalHall() {
        let views = [
            EmbyItem(id: "lib_m", name: "电影", type: "CollectionFolder"),
            EmbyItem(id: "lib_us", name: "欧美剧", type: "CollectionFolder"),
            EmbyItem(id: "lib_anime", name: "动漫", type: "CollectionFolder")
        ]
        let hypedAnime = makeItem(
            id: "a_hyped",
            name: "某某异世界转生神作",
            originalTitle: "異世界転生アニメ",
            type: "Series",
            genres: ["动画", "奇幻"],
            communityRating: 9.4,
            productionYear: 2025,
            studios: [EmbyNameIdPair(id: "st1", name: "MAPPA")]
        )
        let animeMovieInMovieLib = makeItem(
            id: "a_movie",
            name: "热门动漫剧场版",
            originalTitle: "劇場版アニメ",
            type: "Movie",
            genres: ["动画", "动作"],
            communityRating: 9.2,
            productionYear: 2025
        )
        let normalClassic = makeItem(
            id: "m_classic",
            name: "盗梦空间",
            originalTitle: "Inception",
            type: "Movie",
            genres: ["科幻", "动作"],
            communityRating: 8.4,
            criticRating: 87,
            productionYear: 2010
        )

        // 1. Standard non-anime server
        #expect(!HomeHeroCurator.isAnimeFocusedServer(serverName: "我的影视服", libraryViews: views, explicitAnimeMode: nil))
        let nonAnimeSelected = HomeHeroCurator.selectHeroItems(
            libraryViews: views,
            latestByLibrary: [
                "lib_m": [animeMovieInMovieLib, normalClassic],
                "lib_anime": [hypedAnime]
            ],
            maxCount: 8,
            referenceYear: 2026,
            serverName: "我的影视服",
            explicitAnimeMode: nil
        )
        #expect(nonAnimeSelected.map(\.id) == ["m_classic"])

        // 2. UHD Normal Hall (explicitAnimeMode: false)
        let normalHallSelected = HomeHeroCurator.selectHeroItems(
            libraryViews: views,
            latestByLibrary: [
                "lib_m": [animeMovieInMovieLib, normalClassic],
                "lib_anime": [hypedAnime]
            ],
            maxCount: 8,
            referenceYear: 2026,
            serverName: "UHDNow",
            explicitAnimeMode: false
        )
        #expect(normalHallSelected.map(\.id) == ["m_classic"])

        // 3. UHD Anime Hall (explicitAnimeMode: true) & Dedicated Anime Server
        #expect(HomeHeroCurator.isAnimeFocusedServer(serverName: "二次元动漫服", libraryViews: views, explicitAnimeMode: nil))
        let animeHallAudit = HomeHeroCurator.audit(hypedAnime, libraryName: "动漫", referenceYear: 2026, allowAnime: true)
        #expect(animeHallAudit.isAnimeOrAnimation)
        #expect(!animeHallAudit.isAnimeExcluded)
        // Anime fan rating deflation reduces unverified 9.4 significantly
        #expect(animeHallAudit.effectiveRating < 8.5)
    }

    @Test("Thai BL and Korean idol romance are filtered while critic-verified masterpieces are not hard-banned")
    func thaiBLAndKoreanIdolFilteredWhileCriticallyAcclaimedSurvive() {
        let views = [
            EmbyItem(id: "lib_movies", name: "电影", type: "CollectionFolder"),
            EmbyItem(id: "lib_tv", name: "剧集", type: "CollectionFolder")
        ]
        let thaiBL = makeItem(
            id: "th_bl",
            name: "校园心动泰腐剧",
            originalTitle: "ซีรีส์วายยอดนิยม",
            type: "Series",
            genres: ["爱情", "剧情"],
            communityRating: 9.1,
            productionYear: 2025,
            studios: [EmbyNameIdPair(id: "gmm", name: "GMMTV")]
        )
        let koreanIdol = makeItem(
            id: "kr_idol",
            name: "财阀千金恋爱记",
            originalTitle: "재벌집 로맨스",
            type: "Series",
            genres: ["爱情", "喜剧"],
            communityRating: 8.8,
            productionYear: 2025,
            studios: [EmbyNameIdPair(id: "tvn", name: "tvN")]
        )
        let parasite = makeItem(
            id: "kr_parasite",
            name: "寄生虫",
            originalTitle: "기생충",
            type: "Movie",
            genres: ["剧情", "惊悚"],
            communityRating: 8.5,
            criticRating: 99,
            productionYear: 2019
        )
        let badGenius = makeItem(
            id: "th_bad_genius",
            name: "天才枪手",
            originalTitle: "ฉลาดเกมส์โกง",
            type: "Movie",
            genres: ["惊悚", "犯罪", "剧情"],
            communityRating: 7.6,
            criticRating: 92,
            productionYear: 2017
        )
        let westernPrestige = makeItem(
            id: "us_succession",
            name: "继承之战",
            originalTitle: "Succession",
            type: "Series",
            genres: ["剧情"],
            communityRating: 8.3,
            criticRating: 95,
            productionYear: 2018,
            childCount: 4
        )

        let ratings: [String: MultiPlatformRatings] = [
            "th_bl": MultiPlatformRatings(tmdb: 9.1, tmdbVotes: 180, imdb: 9.0, imdbVotes: 1_800, countries: ["Thailand"]),
            "kr_idol": MultiPlatformRatings(tmdb: 8.8, tmdbVotes: 240, imdb: 8.6, imdbVotes: 2_600, countries: ["South Korea"]),
            "kr_parasite": MultiPlatformRatings(tmdb: 8.5, tmdbVotes: 18_000, imdb: 8.5, imdbVotes: 1_000_000, rottenTomatoesCritics: 99, rottenTomatoesAudience: 90, metacritic: 96, letterboxd: 4.5, rogerEbert: 4.0, awardsSummary: "Won 4 Oscars. 309 wins & 265 nominations total", countries: ["South Korea"]),
            "th_bad_genius": MultiPlatformRatings(tmdb: 7.6, tmdbVotes: 900, imdb: 7.6, imdbVotes: 26_000, rottenTomatoesCritics: 92, metacritic: 72, letterboxd: 3.9, countries: ["Thailand"]),
            "us_succession": MultiPlatformRatings(tmdb: 8.3, tmdbVotes: 1_900, imdb: 8.8, imdbVotes: 290_000, rottenTomatoesCritics: 95, metacritic: 89, awardsSummary: "Won 19 Primetime Emmys", countries: ["United States"])
        ]

        let thaiAudit = HomeHeroCurator.audit(thaiBL, libraryName: "剧集", referenceYear: 2026, multiPlatformRatings: ratings["th_bl"])
        let krIdolAudit = HomeHeroCurator.audit(koreanIdol, libraryName: "剧集", referenceYear: 2026, multiPlatformRatings: ratings["kr_idol"])
        let parasiteAudit = HomeHeroCurator.audit(parasite, libraryName: "电影", referenceYear: 2026, multiPlatformRatings: ratings["kr_parasite"])
        let badGeniusAudit = HomeHeroCurator.audit(badGenius, libraryName: "电影", referenceYear: 2026, multiPlatformRatings: ratings["th_bad_genius"])
        let successionAudit = HomeHeroCurator.audit(westernPrestige, libraryName: "剧集", referenceYear: 2026, multiPlatformRatings: ratings["us_succession"])

        #expect(thaiAudit.isThaiOrSEASeries)
        #expect(thaiAudit.isIdolOrBLFiltered)
        #expect(krIdolAudit.isKoreanSeries)
        #expect(krIdolAudit.isIdolOrBLFiltered)
        #expect(!parasiteAudit.isIdolOrBLFiltered)
        #expect(!badGeniusAudit.isIdolOrBLFiltered)
        #expect(parasiteAudit.score > krIdolAudit.score + 120)
        #expect(successionAudit.score > thaiAudit.score + 140)

        let selected = HomeHeroCurator.selectHeroItems(
            libraryViews: views,
            latestByLibrary: [
                "lib_tv": [thaiBL, koreanIdol, westernPrestige],
                "lib_movies": [parasite, badGenius]
            ],
            ratingsByItemId: ratings,
            maxCount: 8,
            referenceYear: 2026
        )
        let ids = selected.map(\.id)
        #expect(ids.contains("kr_parasite"))
        #expect(ids.contains("us_succession"))
        #expect(ids.contains("th_bad_genius"))
        #expect(!ids.contains("th_bl"))
        #expect(!ids.contains("kr_idol"))
    }

    @Test("Professional critic platforms heavily outweigh fan-only audience scores")
    func professionalCriticsOutweighCrowdOnlyRatings() {
        let criticDarling = MultiPlatformRatings(
            tmdb: 7.4, tmdbVotes: 4_000,
            imdb: 7.7, imdbVotes: 160_000,
            rottenTomatoesCritics: 96,
            rottenTomatoesAudience: 79,
            trakt: 74,
            metacritic: 91,
            letterboxd: 4.2,
            rogerEbert: 4.0,
            awardsSummary: "Won 2 Oscars. 45 wins & 80 nominations total"
        )
        let fanBrigaded = MultiPlatformRatings(
            tmdb: 8.9, tmdbVotes: 900,
            imdb: 8.6, imdbVotes: 4_200,
            rottenTomatoesCritics: 52,
            rottenTomatoesAudience: 95,
            trakt: 88,
            metacritic: 49
        )

        let evalCritic = MultiPlatformRatings.evaluate(criticDarling, fallbackTMDB: 7.4, fallbackCriticRating: 96, isMovie: true)
        let evalFan = MultiPlatformRatings.evaluate(fanBrigaded, fallbackTMDB: 8.9, fallbackCriticRating: 52, isMovie: true)

        #expect(evalCritic.professionalCriticCount == 4)
        #expect(evalCritic.hasMajorAwards)
        #expect((evalCritic.weightedScore ?? 0) > 8.6)
        #expect((evalFan.weightedScore ?? 10) < 6.5)
        #expect(evalFan.isRatingInflated)
        #expect(evalCritic.consensusDelta > evalFan.consensusDelta + 90)
    }

    @Test("IMDbOfficialRatingsStore stream-scans gzipped TSV for exact rating and vote counts")
    func imdbOfficialStoreScansGzipTSV() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("donby-imdb-tsv-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let gzURL = tempDir.appendingPathComponent("title.ratings.tsv.gz")
        let tsv = """
        tconst\taverageRating\tnumVotes
        tt0111161\t9.3\t2950000
        tt0903747\t9.5\t2310000
        tt9999999\t9.8\t42
        """
        guard let gz = gzopen(gzURL.path, "wb") else {
            Issue.record("Failed to open gzip file for writing")
            return
        }
        let bytes = Array(tsv.utf8)
        _ = gzwrite(gz, bytes, UInt32(bytes.count))
        gzclose(gz)

        let results = IMDbOfficialRatingsStore.scanGzipTSV(at: gzURL, targetIds: ["tt0111161", "tt9999999", "tt0000000"])
        #expect(results.count == 2)
        #expect(results["tt0111161"] == .init(rating: 9.3, votes: 2_950_000))
        #expect(results["tt9999999"] == .init(rating: 9.8, votes: 42))
        #expect(results["tt0000000"] == nil)
    }

    @Test("Movies receive elevated priority while documentaries are strongly downranked")
    func moviesBoostedAndDocumentariesDownranked() {
        let views = [
            EmbyItem(id: "lib_movies", name: "电影", type: "CollectionFolder"),
            EmbyItem(id: "lib_docs", name: "纪录片", type: "CollectionFolder"),
            EmbyItem(id: "lib_tv", name: "欧美剧", type: "CollectionFolder")
        ]
        let modernMovie = makeItem(
            id: "m_dune2",
            name: "沙丘2",
            originalTitle: "Dune: Part Two",
            type: "Movie",
            genres: ["科幻", "冒险"],
            communityRating: 8.2,
            criticRating: 92,
            productionYear: 2024
        )
        let natureDocSeries = makeItem(
            id: "doc_planet",
            name: "地球脉动",
            originalTitle: "Planet Earth II",
            type: "Series",
            genres: ["纪录", "Documentary"],
            communityRating: 9.1,
            criticRating: 95,
            productionYear: 2016,
            studios: [EmbyNameIdPair(id: "bbc", name: "BBC Earth")]
        )
        let docMovie = makeItem(
            id: "doc_film",
            name: "徒手攀岩",
            originalTitle: "Free Solo",
            type: "Movie",
            genres: ["纪录片"],
            communityRating: 8.1,
            criticRating: 97,
            productionYear: 2018
        )
        let westernSeries = makeItem(
            id: "s_severance",
            name: "人生切割术",
            originalTitle: "Severance",
            type: "Series",
            genres: ["科幻", "悬疑"],
            communityRating: 8.4,
            criticRating: 97,
            productionYear: 2022,
            childCount: 2
        )

        let movieAudit = HomeHeroCurator.audit(modernMovie, libraryName: "电影", referenceYear: 2026)
        let docSeriesAudit = HomeHeroCurator.audit(natureDocSeries, libraryName: "纪录片", referenceYear: 2026)
        let docMovieAudit = HomeHeroCurator.audit(docMovie, libraryName: "电影", referenceYear: 2026)
        let seriesAudit = HomeHeroCurator.audit(westernSeries, libraryName: "欧美剧", referenceYear: 2026)

        #expect(!movieAudit.isDocumentary)
        #expect(docSeriesAudit.isDocumentary)
        #expect(docMovieAudit.isDocumentary)
        #expect(movieAudit.score > seriesAudit.score)
        #expect(movieAudit.score > docSeriesAudit.score + 80)
        #expect(seriesAudit.score > docMovieAudit.score + 60)

        let selected = HomeHeroCurator.selectHeroItems(
            libraryViews: views,
            latestByLibrary: [
                "lib_docs": [natureDocSeries],
                "lib_movies": [docMovie, modernMovie],
                "lib_tv": [westernSeries]
            ],
            maxCount: 2,
            referenceYear: 2026
        )
        #expect(selected.map(\.id) == ["m_dune2", "s_severance"])
    }
}

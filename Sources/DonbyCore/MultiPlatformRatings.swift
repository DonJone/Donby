import Foundation

/// Aggregated multi-platform ratings (TMDB, IMDb, Rotten Tomatoes Critics/Audience, Trakt, Metacritic, Letterboxd)
/// used by `HomeHeroCurator` to prevent single-source low-vote rating distortion.
public struct MultiPlatformRatings: Codable, Sendable, Equatable {
    public var tmdb: Double?                 // 0...10
    public var tmdbVotes: Int?
    public var imdb: Double?                 // 0...10
    public var imdbVotes: Int?
    public var rottenTomatoesCritics: Int?   // 0...100 (Tomatometer)
    public var rottenTomatoesAudience: Int?  // 0...100 (Popcornmeter)
    public var trakt: Int?                   // 0...100
    public var traktVotes: Int?
    public var metacritic: Int?              // 0...100
    public var letterboxd: Double?           // 0...5
    public var mdblistScore: Int?            // 0...100
    public var imdbId: String?
    public var fetchedAt: Date

    public init(
        tmdb: Double? = nil,
        tmdbVotes: Int? = nil,
        imdb: Double? = nil,
        imdbVotes: Int? = nil,
        rottenTomatoesCritics: Int? = nil,
        rottenTomatoesAudience: Int? = nil,
        trakt: Int? = nil,
        traktVotes: Int? = nil,
        metacritic: Int? = nil,
        letterboxd: Double? = nil,
        mdblistScore: Int? = nil,
        imdbId: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.tmdb = tmdb
        self.tmdbVotes = tmdbVotes
        self.imdb = imdb
        self.imdbVotes = imdbVotes
        self.rottenTomatoesCritics = rottenTomatoesCritics
        self.rottenTomatoesAudience = rottenTomatoesAudience
        self.trakt = trakt
        self.traktVotes = traktVotes
        self.metacritic = metacritic
        self.letterboxd = letterboxd
        self.mdblistScore = mdblistScore
        self.imdbId = imdbId
        self.fetchedAt = fetchedAt
    }

    public struct Evaluation: Sendable, Equatable {
        /// Weighted multi-platform score normalized to 0...10.
        public let weightedScore: Double?
        /// Number of authoritative non-TMDB platforms present (IMDb, RT Critics, RT Audience, Metacritic, Trakt, Letterboxd).
        public let authoritativePlatformCount: Int
        /// Total number of platforms contributing to `weightedScore`.
        public let totalPlatformCount: Int
        /// IMDb vote count if available.
        public let imdbVotes: Int
        /// Score delta for `HomeHeroCurator` reflecting multi-platform consensus, vote confidence, or single-platform penalty.
        public let consensusDelta: Double
        /// True when multi-platform consensus indicates a weak/panned title.
        public let isLowConsensus: Bool
        /// True when >= 3 authoritative platforms agree on high quality.
        public let isStrongConsensus: Bool
    }

    /// Evaluates weighted consensus across all available platforms, merging optional Emby fallback fields
    /// (`communityRating` as TMDB and `criticRating` as Rotten Tomatoes Tomatometer).
    public static func evaluate(
        _ external: MultiPlatformRatings?,
        fallbackTMDB: Double?,
        fallbackCriticRating: Double?,
        hasImdbProviderId: Bool = false,
        isDomesticSeries: Bool = false
    ) -> Evaluation {
        let rawTMDB = validTenScale(external?.tmdb) ?? validTenScale(fallbackTMDB)
        let rawIMDb = validTenScale(external?.imdb)
        let rawRTCritics: Int? = {
            if let v = external?.rottenTomatoesCritics, v > 0 && v <= 100 { return v }
            if let c = fallbackCriticRating, c > 0 && c <= 100 { return Int(c.rounded()) }
            return nil
        }()
        let rawRTAudience = (external?.rottenTomatoesAudience).flatMap { ($0 > 0 && $0 <= 100) ? $0 : nil }
        let rawTrakt = (external?.trakt).flatMap { ($0 > 0 && $0 <= 100) ? $0 : nil }
        let rawMetacritic = (external?.metacritic).flatMap { ($0 > 0 && $0 <= 100) ? $0 : nil }
        let rawLetterboxd = (external?.letterboxd).flatMap { ($0 > 0 && $0 <= 5.0) ? $0 : nil }

        // Apply Bayesian vote-count shrinkage when vote counts are available so 5-vote 9.5 entries don't game rankings.
        let effIMDb = rawIMDb.map { bayesianShrink(score: $0, votes: external?.imdbVotes, prior: 6.2, minVotes: 1500) }
        let effTMDB = rawTMDB.map { bayesianShrink(score: $0, votes: external?.tmdbVotes, prior: 6.2, minVotes: 250) }
        let effTrakt = rawTrakt.map {
            let tenScale = Double($0) / 10.0
            return bayesianShrink(score: tenScale, votes: external?.traktVotes, prior: 6.4, minVotes: 300)
        }
        let effRTCritics = rawRTCritics.map { Double($0) / 10.0 }
        let effRTAudience = rawRTAudience.map { Double($0) / 10.0 }
        let effMetacritic = rawMetacritic.map { Double($0) / 10.0 }
        let effLetterboxd = rawLetterboxd.map { $0 * 2.0 }

        var weightedSum: Double = 0
        var weightTotal: Double = 0
        var authCount = 0
        var totalCount = 0

        func add(_ value: Double?, weight: Double, authoritative: Bool) {
            guard let value else { return }
            weightedSum += value * weight
            weightTotal += weight
            totalCount += 1
            if authoritative { authCount += 1 }
        }

        // Weights: IMDb 0.30, RT Critics 0.18, Metacritic 0.16, TMDB 0.14, RT Audience 0.12, Trakt 0.10, Letterboxd 0.08
        add(effIMDb, weight: 0.30, authoritative: true)
        add(effRTCritics, weight: 0.18, authoritative: true)
        add(effMetacritic, weight: 0.16, authoritative: true)
        add(effTMDB, weight: 0.14, authoritative: false)
        add(effRTAudience, weight: 0.12, authoritative: true)
        add(effTrakt, weight: 0.10, authoritative: true)
        add(effLetterboxd, weight: 0.08, authoritative: true)

        let weightedScore = weightTotal > 0 ? (weightedSum / weightTotal) : nil
        let imdbVotes = external?.imdbVotes ?? 0

        var delta: Double = 0
        var isLowConsensus = false
        var isStrongConsensus = false

        if let ws = weightedScore {
            // 1. Multi-platform consensus bonus / verification
            if authCount >= 3 && ws >= 7.6 {
                isStrongConsensus = true
                delta += 26
            } else if authCount >= 2 && ws >= 7.2 {
                delta += 16
            } else if authCount >= 1 && ws >= 7.0 {
                delta += 8
            } else if authCount == 0 {
                // Only TMDB present (no IMDb / RT / Metacritic / Trakt verification)
                // If item doesn't even have an IMDb provider ID, apply stronger credibility penalty.
                if isDomesticSeries {
                    delta -= hasImdbProviderId ? 14 : 22
                } else {
                    delta -= hasImdbProviderId ? 6 : 14
                }
            }

            // 2. Popularity / vote-depth confidence (IMDb votes)
            if imdbVotes >= 100_000 {
                delta += 14
            } else if imdbVotes >= 30_000 {
                delta += 10
            } else if imdbVotes >= 5_000 {
                delta += 5
            } else if let v = external?.imdbVotes, v > 0 && v < 400 {
                // Extremely obscure title on IMDb
                delta -= 12
            }

            // 3. Rotten / panned / low-consensus penalties
            if ws < 6.4 {
                isLowConsensus = true
                delta -= 24
            } else if ws < 6.9 && authCount >= 2 {
                delta -= 10
            }

            if let rt = rawRTCritics, rt < 55 {
                delta -= 12
                if let mc = rawMetacritic, mc < 55 {
                    isLowConsensus = true
                    delta -= 14
                }
            }

            if let imdb = rawIMDb, imdb < 6.3 {
                isLowConsensus = true
                delta -= 16
            }

            // 4. Bonus for certified-fresh / critically acclaimed multi-platform harmony
            if let rt = rawRTCritics, rt >= 85, let aud = rawRTAudience, aud >= 80 {
                delta += 10
            }
            if let mc = rawMetacritic, mc >= 78 {
                delta += 8
            }
        }

        return Evaluation(
            weightedScore: weightedScore,
            authoritativePlatformCount: authCount,
            totalPlatformCount: totalCount,
            imdbVotes: imdbVotes,
            consensusDelta: delta,
            isLowConsensus: isLowConsensus,
            isStrongConsensus: isStrongConsensus
        )
    }

    private static func validTenScale(_ value: Double?) -> Double? {
        guard let value, value > 0 && value <= 10.0 else { return nil }
        return value
    }

    private static func bayesianShrink(score: Double, votes: Int?, prior: Double, minVotes: Double) -> Double {
        guard let votes, votes > 0 else { return score }
        let v = Double(votes)
        return (v / (v + minVotes)) * score + (minVotes / (v + minVotes)) * prior
    }
}

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
        /// True when a perfect / near-perfect rating (>= 9.4 movie or >= 9.5 series, or 9.6+ overall) lacks verified multi-platform vote backing.
        public let isSuspiciousPerfectRating: Bool
        /// True when rating appears inflated (unverified high single-source, fan-brigaded anime, or audience-vs-critic divergence).
        public let isRatingInflated: Bool
    }

    /// Evaluates weighted consensus across all available platforms, merging optional Emby fallback fields
    /// (`communityRating` as TMDB and `criticRating` as Rotten Tomatoes Tomatometer).
    public static func evaluate(
        _ external: MultiPlatformRatings?,
        fallbackTMDB: Double?,
        fallbackCriticRating: Double?,
        hasImdbProviderId: Bool = false,
        isDomesticSeries: Bool = false,
        isMovie: Bool = false,
        isAnime: Bool = false
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

        let imdbVotes = external?.imdbVotes ?? 0
        let tmdbVotes = external?.tmdbVotes ?? 0

        // Count authoritative non-TMDB platforms up front so verification checks can use it.
        var preAuthCount = 0
        if rawIMDb != nil { preAuthCount += 1 }
        if rawRTCritics != nil { preAuthCount += 1 }
        if rawMetacritic != nil { preAuthCount += 1 }
        if rawRTAudience != nil { preAuthCount += 1 }
        if rawTrakt != nil { preAuthCount += 1 }
        if rawLetterboxd != nil { preAuthCount += 1 }

        // Perfect / near-perfect score verification:
        // Real cinema/TV history tops out around IMDb 9.3 (movies) / 9.5 (series).
        // Scores >= 9.4 (movies) or >= 9.5 (series) MUST be backed by multi-platform consensus,
        // substantial vote depth, and non-contradicting critics.
        let extremeThreshold: Double = isMovie ? 9.4 : 9.5
        let highestRawCommunity = max(rawTMDB ?? 0, rawIMDb ?? 0)
        let criticSupportsExtreme: Bool = {
            if let mc = rawMetacritic, mc < 75 { return false }
            if let rt = rawRTCritics, rt < 75 { return false }
            return rawMetacritic != nil || rawRTCritics != nil
        }()
        let hasSubstantialVotes = imdbVotes >= 15_000
            || tmdbVotes >= 1_500
            || (imdbVotes >= 5_000 && (rawRTCritics ?? 0) >= 85)
        let extremeVerified = preAuthCount >= 2 && hasSubstantialVotes && criticSupportsExtreme

        var isSuspiciousPerfectRating = false
        var isRatingInflated = false
        var suspiciousPenalty: Double = 0

        if highestRawCommunity >= extremeThreshold && !extremeVerified {
            isSuspiciousPerfectRating = true
            isRatingInflated = true
            if highestRawCommunity >= 9.8 {
                // Exact 10.0 / 9.9 / 9.8 without high-vote multi-platform verification is almost always 1-vote junk or brigading.
                suspiciousPenalty -= 44
            } else if highestRawCommunity >= 9.6 {
                suspiciousPenalty -= 34
            } else {
                suspiciousPenalty -= 24
            }
        } else if let lb = rawLetterboxd, lb >= 4.8, preAuthCount < 2 {
            isSuspiciousPerfectRating = true
            isRatingInflated = true
            suspiciousPenalty -= 24
        }

        // Apply strict Bayesian vote-count shrinkage (higher thresholds for anime to counter fan brigading).
        let imdbMinVotes: Double = isAnime ? 6000 : 2500
        let tmdbMinVotes: Double = isAnime ? 1500 : 500
        let traktMinVotes: Double = isAnime ? 1200 : 400

        var effIMDb = rawIMDb.map { raw -> Double in
            let shrunk = bayesianShrink(score: raw, votes: external?.imdbVotes, prior: 6.2, minVotes: imdbMinVotes)
            if external?.imdbVotes == nil && raw >= extremeThreshold && !extremeVerified {
                return min(shrunk, 6.6)
            }
            return shrunk
        }

        var effTMDB = rawTMDB.map { raw -> Double in
            if let votes = external?.tmdbVotes, votes > 0 {
                let shrunk = bayesianShrink(score: raw, votes: votes, prior: 6.2, minVotes: tmdbMinVotes)
                if raw >= extremeThreshold && !extremeVerified {
                    return min(shrunk, raw >= 9.8 ? 6.2 : 6.7)
                }
                return shrunk
            }
            // Unknown vote count (Emby communityRating / UHD rating):
            // Deflate suspicious perfect scores harshly and compress unverified high scores above 8.4.
            if raw >= 9.8 && !extremeVerified {
                return 6.2
            }
            if raw >= extremeThreshold && !extremeVerified {
                return 6.7
            }
            if preAuthCount == 0 && raw > 8.4 {
                return 8.4 + (raw - 8.4) * 0.42
            }
            return raw
        }

        var effTrakt = rawTrakt.map { raw -> Double in
            let tenScale = Double(raw) / 10.0
            let shrunk = bayesianShrink(score: tenScale, votes: external?.traktVotes, prior: 6.3, minVotes: traktMinVotes)
            if external?.traktVotes == nil && tenScale >= 9.4 && !extremeVerified {
                return 6.8
            }
            return shrunk
        }
        let effRTCritics = rawRTCritics.map { Double($0) / 10.0 }
        var effRTAudience = rawRTAudience.map { Double($0) / 10.0 }
        let effMetacritic = rawMetacritic.map { Double($0) / 10.0 }
        let effLetterboxd = rawLetterboxd.map { $0 * 2.0 }

        // Anime fan rating deflation: anime fanbases systematically over-rate shows by ~0.7–1.2 points.
        if isAnime {
            let animeDeflation = 0.75
            if let v = effTMDB { effTMDB = max(1.0, v - animeDeflation) }
            if let v = effTrakt { effTrakt = max(1.0, v - animeDeflation) }
            if let v = effRTAudience { effRTAudience = max(1.0, v - animeDeflation) }
            if let v = effIMDb, imdbVotes < 50_000 {
                effIMDb = max(1.0, v - (imdbVotes == 0 ? 0.70 : 0.45))
            }
        }

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

        var delta: Double = suspiciousPenalty
        var isLowConsensus = false
        var isStrongConsensus = false

        if let ws = weightedScore {
            // 1. Multi-platform consensus bonus / verification
            if authCount >= 3 && ws >= 7.6 && !isSuspiciousPerfectRating {
                isStrongConsensus = true
                delta += 28
            } else if authCount >= 2 && ws >= 7.2 && !isSuspiciousPerfectRating {
                delta += 18
            } else if authCount >= 1 && ws >= 7.0 && !isSuspiciousPerfectRating {
                delta += 9
            } else if authCount == 0 {
                // Only TMDB present (no IMDb / RT / Metacritic / Trakt verification)
                if isDomesticSeries {
                    delta -= hasImdbProviderId ? 16 : 24
                } else {
                    delta -= hasImdbProviderId ? 8 : 16
                }
                // Extra inflation guard when single-source TMDB has unknown votes and suspiciously high score >= 9.0.
                if let t = rawTMDB, t >= 9.0, external?.tmdbVotes == nil, !isSuspiciousPerfectRating {
                    isRatingInflated = true
                    delta -= 10
                }
                if isAnime, let t = rawTMDB, t >= 8.6 {
                    isRatingInflated = true
                    delta -= 16
                }
            }

            // 2. Popularity / vote-depth confidence (IMDb votes)
            if imdbVotes >= 100_000 {
                delta += 16
            } else if imdbVotes >= 30_000 {
                delta += 11
            } else if imdbVotes >= 5_000 {
                delta += 6
            } else if let v = external?.imdbVotes, v > 0 && v < 800 {
                // Obscure / low-sample title on IMDb
                delta -= 16
            }

            // 3. Audience-vs-critic divergence (fan-brigaded titles with weak critical reception)
            let fanScore = max(rawTMDB ?? 0, effRTAudience ?? 0, rawTrakt.map { Double($0) / 10.0 } ?? 0)
            let criticValues = [effRTCritics, effMetacritic].compactMap { $0 }
            if !criticValues.isEmpty {
                let avgCritic = criticValues.reduce(0, +) / Double(criticValues.count)
                if fanScore >= 8.4 && avgCritic < 6.6 && (fanScore - avgCritic) >= 1.9 {
                    isRatingInflated = true
                    delta -= 18
                }
            }

            // 4. Rotten / panned / low-consensus penalties
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

            // 5. Bonus for certified-fresh / critically acclaimed multi-platform harmony
            if let rt = rawRTCritics, rt >= 85, let aud = rawRTAudience, aud >= 80, !isSuspiciousPerfectRating {
                delta += 10
            }
            if let mc = rawMetacritic, mc >= 78, !isSuspiciousPerfectRating {
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
            isStrongConsensus: isStrongConsensus,
            isSuspiciousPerfectRating: isSuspiciousPerfectRating,
            isRatingInflated: isRatingInflated
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

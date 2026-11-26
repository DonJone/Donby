import Foundation

/// Regional / genre rating-bias profile used to counter systematic fan-brigading
/// and self-selection inflation on community voting platforms (TMDB, IMDb, Trakt, RT Audience).
public enum RatingBiasProfile: String, Codable, Sendable, Equatable {
    /// Western mainstream films/series and neutral works with broad cross-demographic voting.
    case standard
    /// Anime / animation where fandom voting systematically inflates community scores.
    case anime
    /// Korean dramas (K-drama) prone to organized 10-star actor/CP fandom voting with low Western critic coverage.
    case koreanDrama
    /// Thai / SEA dramas (especially Thai BL / Y-series / Lakorn) with extreme small-sample fandom 10-star inflation.
    case thaiOrSEADrama
    /// Chinese domestic dramas prone to localized rating noise and low global vote volume.
    case domesticDrama
}

/// Aggregated multi-platform ratings across professional critic and audience platforms
/// (Metacritic, Rotten Tomatoes Critics, Letterboxd, RogerEbert, IMDb + votes, Trakt + votes,
/// Rotten Tomatoes Audience, TMDB + votes, plus major awards & production countries)
/// used by `HomeHeroCurator` to prioritize verified critical consensus over fandom inflation.
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
    public var rogerEbert: Double?           // 0...4
    public var mdblistScore: Int?            // 0...100
    public var imdbId: String?
    public var awardsSummary: String?
    public var countries: [String]?
    public var mdblistFetched: Bool?
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
        rogerEbert: Double? = nil,
        mdblistScore: Int? = nil,
        imdbId: String? = nil,
        awardsSummary: String? = nil,
        countries: [String]? = nil,
        mdblistFetched: Bool? = nil,
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
        self.rogerEbert = rogerEbert
        self.mdblistScore = mdblistScore
        self.imdbId = imdbId
        self.awardsSummary = awardsSummary
        self.countries = countries
        self.mdblistFetched = mdblistFetched
        self.fetchedAt = fetchedAt
    }

    public struct Evaluation: Sendable, Equatable {
        /// Critic-first weighted multi-platform score normalized to 0...10.
        public let weightedScore: Double?
        /// Number of authoritative non-TMDB platforms present (Metacritic, RT Critics, Letterboxd, RogerEbert, IMDb, RT Audience, Trakt).
        public let authoritativePlatformCount: Int
        /// Number of high-professionalism critic/cinephile platforms present (Metacritic, RT Critics, Letterboxd, RogerEbert).
        public let professionalCriticCount: Int
        /// Total number of platforms contributing to `weightedScore`.
        public let totalPlatformCount: Int
        /// IMDb vote count if available.
        public let imdbVotes: Int
        /// True when prestigious professional awards (Oscars, Emmys, Golden Globes, BAFTA, Cannes/Venice/Berlin) are present.
        public let hasMajorAwards: Bool
        /// True when professional critics strongly endorse the title (Metacritic >= 76, RT Critics >= 85, or major awards).
        public let hasStrongCriticEndorsement: Bool
        /// Score delta for `HomeHeroCurator` reflecting critic consensus, vote depth, awards, and anti-inflation penalties.
        public let consensusDelta: Double
        /// True when multi-platform consensus indicates a weak/panned title.
        public let isLowConsensus: Bool
        /// True when >= 3 authoritative platforms (including critic backing) agree on high quality.
        public let isStrongConsensus: Bool
        /// True when a perfect / near-perfect rating (>= 9.4 movie or >= 9.5 series) lacks verified multi-platform vote + critic backing.
        public let isSuspiciousPerfectRating: Bool
        /// True when rating appears inflated (unverified high single-source, fandom brigading, or audience-vs-critic divergence).
        public let isRatingInflated: Bool
    }

    /// Evaluates critic-first weighted consensus across all available platforms, merging optional Emby fallback fields
    /// (`communityRating` as TMDB and `criticRating` as Rotten Tomatoes Tomatometer).
    public static func evaluate(
        _ external: MultiPlatformRatings?,
        fallbackTMDB: Double?,
        fallbackCriticRating: Double?,
        hasImdbProviderId: Bool = false,
        isDomesticSeries: Bool = false,
        isMovie: Bool = false,
        isAnime: Bool = false,
        biasProfile: RatingBiasProfile? = nil
    ) -> Evaluation {
        let profile: RatingBiasProfile = {
            if let explicit = biasProfile { return explicit }
            if isAnime { return .anime }
            if isDomesticSeries { return .domesticDrama }
            return .standard
        }()

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
        let rawRogerEbert = (external?.rogerEbert).flatMap { ($0 > 0 && $0 <= 4.0) ? $0 : nil }

        let imdbVotes = external?.imdbVotes ?? 0
        let tmdbVotes = external?.tmdbVotes ?? 0
        let awardsBoost = evaluateAwardsBoost(external?.awardsSummary)
        let hasMajorAwards = awardsBoost >= 7.0

        var preAuthCount = 0
        var profCriticCount = 0
        if rawIMDb != nil { preAuthCount += 1 }
        if rawRTCritics != nil { preAuthCount += 1; profCriticCount += 1 }
        if rawMetacritic != nil { preAuthCount += 1; profCriticCount += 1 }
        if rawLetterboxd != nil { preAuthCount += 1; profCriticCount += 1 }
        if rawRogerEbert != nil { preAuthCount += 1; profCriticCount += 1 }
        if rawRTAudience != nil { preAuthCount += 1 }
        if rawTrakt != nil { preAuthCount += 1 }

        let hasStrongCriticEndorsement =
            (rawMetacritic ?? 0) >= 76
            || (rawRTCritics ?? 0) >= 85
            || (rawLetterboxd ?? 0) >= 4.0
            || (rawRogerEbert ?? 0) >= 3.5
            || hasMajorAwards

        // Perfect / near-perfect score verification:
        // Real cinema/TV history tops out around IMDb 9.3 (movies) / 9.5 (series).
        // Scores >= 9.4 (movies) or >= 9.5 (series) MUST be backed by multi-platform consensus,
        // substantial vote depth, and non-contradicting professional critics.
        let extremeThreshold: Double = isMovie ? 9.4 : 9.5
        let highestRawCommunity = max(rawTMDB ?? 0, rawIMDb ?? 0)
        let criticSupportsExtreme: Bool = {
            if let mc = rawMetacritic, mc < 75 { return false }
            if let rt = rawRTCritics, rt < 75 { return false }
            return rawMetacritic != nil || rawRTCritics != nil || hasMajorAwards
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

        // Profile-specific Bayesian vote minimums & crowd deflation (targets fan-brigading in anime, K-drama, Thai BL/Lakorn).
        let (imdbMinVotes, tmdbMinVotes, traktMinVotes, crowdDeflation): (Double, Double, Double, Double) = switch profile {
        case .standard:       (2_500, 500, 400, 0.0)
        case .domesticDrama:  (2_500, 400, 400, 0.20)
        case .anime:          (6_000, 1_500, 1_200, 0.75)
        case .koreanDrama:    (12_000, 1_500, 1_200, 0.90)
        case .thaiOrSEADrama: (15_000, 2_000, 1_500, 1.25)
        }

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
            if raw >= 9.8 && !extremeVerified { return 6.2 }
            if raw >= extremeThreshold && !extremeVerified { return 6.7 }
            if preAuthCount == 0 && raw > 8.4 {
                return 8.4 + (raw - 8.4) * 0.40
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
        let effRogerEbert = rawRogerEbert.map { $0 * 2.5 }

        // Apply fandom-inflation deflation strictly to crowd/audience platforms (never to professional critics!).
        if crowdDeflation > 0 {
            if let v = effTMDB { effTMDB = max(1.0, v - crowdDeflation) }
            if let v = effTrakt { effTrakt = max(1.0, v - crowdDeflation) }
            if let v = effRTAudience { effRTAudience = max(1.0, v - crowdDeflation) }
            if let v = effIMDb {
                // Only truly massive global IMDb vote counts (>= 80k) escape regional fandom deflation.
                let imdbFactor: Double = imdbVotes >= 80_000 ? 0.0 : (imdbVotes >= 25_000 ? 0.40 : (imdbVotes > 0 ? 0.75 : 0.90))
                effIMDb = max(1.0, v - crowdDeflation * imdbFactor)
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

        // Critic-First Weight Hierarchy (~76% professional critic & cinephile platforms, ~24% crowd platforms):
        // Metacritic 0.30 | RT Critics 0.22 | Letterboxd 0.16 | RogerEbert 0.08 | IMDb 0.14 | Trakt 0.04 | RT Audience 0.03 | TMDB 0.03
        add(effMetacritic, weight: 0.30, authoritative: true)
        add(effRTCritics, weight: 0.22, authoritative: true)
        add(effLetterboxd, weight: 0.16, authoritative: true)
        add(effRogerEbert, weight: 0.08, authoritative: true)
        add(effIMDb, weight: 0.14, authoritative: true)
        add(effTrakt, weight: 0.04, authoritative: true)
        add(effRTAudience, weight: 0.03, authoritative: true)
        add(effTMDB, weight: 0.03, authoritative: false)

        let weightedScore = weightTotal > 0 ? (weightedSum / weightTotal) : nil

        var delta: Double = suspiciousPenalty + awardsBoost
        var isLowConsensus = false
        var isStrongConsensus = false

        if let ws = weightedScore {
            // 1. Multi-platform consensus bonus (professional critic presence carries decisive weight)
            if authCount >= 3 && profCriticCount >= 2 && ws >= 7.6 && !isSuspiciousPerfectRating {
                isStrongConsensus = true
                delta += 34
            } else if authCount >= 3 && ws >= 7.6 && !isSuspiciousPerfectRating {
                isStrongConsensus = true
                delta += 26
            } else if authCount >= 2 && profCriticCount >= 1 && ws >= 7.2 && !isSuspiciousPerfectRating {
                delta += 20
            } else if authCount >= 2 && ws >= 7.2 && !isSuspiciousPerfectRating {
                delta += 14
            } else if authCount >= 1 && profCriticCount >= 1 && ws >= 7.0 && !isSuspiciousPerfectRating {
                delta += 12
            } else if authCount >= 1 && ws >= 7.0 && !isSuspiciousPerfectRating {
                delta += 6
            } else if authCount == 0 {
                switch profile {
                case .thaiOrSEADrama: delta -= hasImdbProviderId ? 22 : 30
                case .koreanDrama:    delta -= hasImdbProviderId ? 18 : 26
                case .domesticDrama:  delta -= hasImdbProviderId ? 14 : 20
                case .anime:          delta -= hasImdbProviderId ? 14 : 20
                case .standard:       delta -= hasImdbProviderId ? 8 : 16
                }
                if let t = rawTMDB, t >= 9.0, external?.tmdbVotes == nil, !isSuspiciousPerfectRating {
                    isRatingInflated = true
                    delta -= 12
                }
                if (profile == .anime || profile == .koreanDrama || profile == .thaiOrSEADrama), let t = rawTMDB, t >= 8.5 {
                    isRatingInflated = true
                    delta -= 16
                }
            }

            // 2. Professional Critic Endorsement & Absence Guardrail
            if !isSuspiciousPerfectRating {
                if let mc = rawMetacritic, mc >= 78, let rt = rawRTCritics, rt >= 85 {
                    delta += 24
                } else {
                    if let mc = rawMetacritic {
                        if mc >= 80 { delta += 18 }
                        else if mc >= 72 { delta += 10 }
                    }
                    if let rt = rawRTCritics {
                        if rt >= 86 { delta += 14 }
                        else if rt >= 75 { delta += 7 }
                    }
                }
                if let lb = rawLetterboxd {
                    if lb >= 4.0 { delta += 14 }
                    else if lb >= 3.6 { delta += 7 }
                }
                if let re = rawRogerEbert, re >= 3.5 {
                    delta += 8
                }
            }

            if profCriticCount == 0 && !hasMajorAwards && authCount > 0 {
                // High crowd scores with zero professional critic coverage are a prime fandom-inflation vector.
                switch profile {
                case .thaiOrSEADrama: delta -= 22
                case .koreanDrama:    delta -= 14
                case .anime:          delta -= 10
                case .domesticDrama:
                    if (rawIMDb ?? 0) < 8.0 || imdbVotes < 3_000 { delta -= 8 }
                case .standard:       break
                }
            }

            // 3. Global Vote-Depth Confidence (IMDb official vote volume)
            if imdbVotes >= 300_000 {
                delta += 20
            } else if imdbVotes >= 100_000 {
                delta += 15
            } else if imdbVotes >= 30_000 {
                delta += 10
            } else if imdbVotes >= 5_000 {
                delta += 6
            } else if let v = external?.imdbVotes, v > 0 {
                if v < 1_000 {
                    delta -= 18
                } else if v < 3_500 && (profile == .anime || profile == .koreanDrama || profile == .thaiOrSEADrama) {
                    // Classic small-sample fandom echo chamber (e.g. 1,500 fans brigading a Thai BL or K-drama)
                    isRatingInflated = true
                    delta -= 20
                }
            }

            // 4. Audience-vs-Critic Divergence (fan-brigaded titles rejected by professional critics)
            let fanScore = max(rawTMDB ?? 0, effRTAudience ?? 0, rawTrakt.map { Double($0) / 10.0 } ?? 0)
            let criticValues = [effMetacritic, effRTCritics, effLetterboxd, effRogerEbert].compactMap { $0 }
            if !criticValues.isEmpty {
                let avgCritic = criticValues.reduce(0, +) / Double(criticValues.count)
                if fanScore >= 8.2 && avgCritic < 6.8 && (fanScore - avgCritic) >= 1.6 {
                    isRatingInflated = true
                    delta -= 22
                }
            }

            // 5. Rotten / Panned / Low-Consensus Penalties
            if ws < 6.4 {
                isLowConsensus = true
                delta -= 26
            } else if ws < 6.9 && authCount >= 2 {
                delta -= 12
            }

            if let mc = rawMetacritic, mc < 55 {
                delta -= 16
                if mc < 45 { isLowConsensus = true; delta -= 10 }
            }
            if let rt = rawRTCritics, rt < 55 {
                delta -= 14
                if let mc = rawMetacritic, mc < 58 {
                    isLowConsensus = true
                    delta -= 14
                }
            }
            if let imdb = rawIMDb, imdb < 6.3 {
                isLowConsensus = true
                delta -= 16
            }
        }

        return Evaluation(
            weightedScore: weightedScore,
            authoritativePlatformCount: authCount,
            professionalCriticCount: profCriticCount,
            totalPlatformCount: totalCount,
            imdbVotes: imdbVotes,
            hasMajorAwards: hasMajorAwards,
            hasStrongCriticEndorsement: hasStrongCriticEndorsement,
            consensusDelta: delta,
            isLowConsensus: isLowConsensus,
            isStrongConsensus: isStrongConsensus,
            isSuspiciousPerfectRating: isSuspiciousPerfectRating,
            isRatingInflated: isRatingInflated
        )
    }

    /// Extracts a bounded professional-prestige bonus from Cinemeta / OMDb awards strings
    /// (e.g. "Won 4 Oscars", "Won 16 Primetime Emmys", "Nominated for 7 Oscars").
    public static func evaluateAwardsBoost(_ summary: String?) -> Double {
        guard let raw = summary?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return 0
        }
        let lower = raw.lowercased()
        if lower == "n/a" || lower == "none" { return 0 }

        var boost: Double = 0
        if lower.contains("won") && (lower.contains("oscar") || lower.contains("academy award")) {
            boost = max(boost, 16)
        } else if lower.contains("nominated") && (lower.contains("oscar") || lower.contains("academy award")) {
            boost = max(boost, 11)
        }

        if lower.contains("won") && (lower.contains("emmy") || lower.contains("bafta") || lower.contains("golden globe") || lower.contains("palme d'or") || lower.contains("golden lion") || lower.contains("golden bear")) {
            boost = max(boost, 14)
        } else if lower.contains("nominated") && (lower.contains("emmy") || lower.contains("bafta") || lower.contains("golden globe")) {
            boost = max(boost, 8)
        }

        if boost == 0,
           let range = lower.range(of: #"(\d+)\s+wins?"#, options: .regularExpression),
           let numStr = lower[range].split(separator: " ").first,
           let wins = Int(numStr), wins >= 12 {
            boost = 6
        }
        return boost
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

    // MARK: - Hero Display Badges

    /// Ordered visual rating platforms displayed on Home and Detail hero posters.
    public enum RatingPlatform: String, CaseIterable, Sendable, Identifiable {
        case tmdb
        case imdb
        case rottenTomatoesCritics
        case rottenTomatoesAudience
        case letterboxd
        case trakt
        case metacritic

        public var id: String { rawValue }
    }

    /// Single formatted rating badge ready for rendering on hero posters.
    public struct RatingBadgeItem: Identifiable, Equatable, Sendable {
        public let platform: RatingPlatform
        public let formattedValue: String
        public let isPositive: Bool
        public let tooltip: String

        public var id: String { platform.rawValue }

        public init(platform: RatingPlatform, formattedValue: String, isPositive: Bool = true, tooltip: String) {
            self.platform = platform
            self.formattedValue = formattedValue
            self.isPositive = isPositive
            self.tooltip = tooltip
        }
    }

    /// Builds ordered visual rating badges for an `EmbyItem`, merging optional multi-platform ratings
    /// with item-level `communityRating` (TMDB) and `criticRating` (Rotten Tomatoes Tomatometer) fallbacks.
    public static func displayBadges(
        for item: EmbyItem,
        external: MultiPlatformRatings?
    ) -> [RatingBadgeItem] {
        displayBadges(
            external: external,
            fallbackTMDB: item.communityRating,
            fallbackCriticRating: item.criticRating
        )
    }

    /// Builds ordered visual rating badges from multi-platform data plus optional Emby fallbacks.
    public static func displayBadges(
        external: MultiPlatformRatings?,
        fallbackTMDB: Double?,
        fallbackCriticRating: Double?
    ) -> [RatingBadgeItem] {
        var badges: [RatingBadgeItem] = []

        if let tmdb = validTenScale(external?.tmdb) ?? validTenScale(fallbackTMDB) {
            let text = String(format: "%.1f", tmdb)
            let tip: String
            if let votes = external?.tmdbVotes, votes > 0 {
                tip = "TMDB \(text) (\(formatCompactVotes(votes)) 票)"
            } else {
                tip = "TMDB \(text)"
            }
            badges.append(RatingBadgeItem(platform: .tmdb, formattedValue: text, isPositive: tmdb >= 6.0, tooltip: tip))
        }

        if let imdb = validTenScale(external?.imdb) {
            let text = String(format: "%.1f", imdb)
            let tip: String
            if let votes = external?.imdbVotes, votes > 0 {
                tip = "IMDb \(text) (\(formatCompactVotes(votes)) 票)"
            } else {
                tip = "IMDb \(text)"
            }
            badges.append(RatingBadgeItem(platform: .imdb, formattedValue: text, isPositive: imdb >= 6.0, tooltip: tip))
        }

        let rtCritics: Int? = {
            if let v = external?.rottenTomatoesCritics, (1...100).contains(v) { return v }
            if let fb = fallbackCriticRating, fb >= 1 && fb <= 100 { return Int(fb.rounded()) }
            return nil
        }()
        if let rtCritics {
            let isFresh = rtCritics >= 60
            badges.append(RatingBadgeItem(
                platform: .rottenTomatoesCritics,
                formattedValue: "\(rtCritics)%",
                isPositive: isFresh,
                tooltip: "烂番茄影评人 \(rtCritics)% (\(isFresh ? "新鲜" : "烂"))"
            ))
        }

        if let rtAudience = external?.rottenTomatoesAudience, (1...100).contains(rtAudience) {
            let isFresh = rtAudience >= 60
            badges.append(RatingBadgeItem(
                platform: .rottenTomatoesAudience,
                formattedValue: "\(rtAudience)%",
                isPositive: isFresh,
                tooltip: "烂番茄观众爆米花指数 \(rtAudience)%"
            ))
        }

        if let rawLB = external?.letterboxd, rawLB > 0 {
            let tenScale = rawLB <= 5.0 ? min(10.0, rawLB * 2.0) : min(10.0, rawLB)
            let text = String(format: "%.1f", tenScale)
            let tip = rawLB <= 5.0
                ? String(format: "Letterboxd %.1f/5 (折合 %@)", rawLB, text)
                : "Letterboxd \(text)"
            badges.append(RatingBadgeItem(platform: .letterboxd, formattedValue: text, isPositive: tenScale >= 6.0, tooltip: tip))
        }

        if let trakt = external?.trakt, (1...100).contains(trakt) {
            let tip: String
            if let votes = external?.traktVotes, votes > 0 {
                tip = "Trakt \(trakt)% (\(formatCompactVotes(votes)) 票)"
            } else {
                tip = "Trakt \(trakt)%"
            }
            badges.append(RatingBadgeItem(platform: .trakt, formattedValue: "\(trakt)%", isPositive: trakt >= 60, tooltip: tip))
        }

        if let mc = external?.metacritic, (1...100).contains(mc) {
            let tenScale = Double(mc) / 10.0
            let text = String(format: "%.1f", tenScale)
            badges.append(RatingBadgeItem(
                platform: .metacritic,
                formattedValue: text,
                isPositive: mc >= 61,
                tooltip: "Metacritic \(mc)/100"
            ))
        }

        return badges
    }

    private static func formatCompactVotes(_ votes: Int) -> String {
        if votes >= 10_000 {
            return String(format: "%.1f万", Double(votes) / 10_000.0)
        }
        return "\(votes)"
    }
}

import Foundation

/// Curates the home hero carousel (`carouselItems`) from library candidates.
///
/// Ranking priorities:
/// 1. Boosts classic movies, critically-acclaimed Western series, and professional critic consensus (Metacritic / RT Critics / Letterboxd / Major Awards).
/// 2. Deflates fandom-brigaded Korean & Thai/SEA dramas and strongly filters idol / BL / romance / soap dramas without hard-banning verified masterpieces.
/// 3. Strictly audits cheap domestic web dramas / micro-dramas and excludes anime on non-anime servers and UHD Normal Hall.
public enum HomeHeroCurator {
    public struct AuditResult: Sendable, Equatable {
        public let score: Double
        public let effectiveRating: Double
        public let isClassicMovie: Bool
        public let isForeignSeries: Bool
        public let isForeignMovie: Bool
        public let isKoreanSeries: Bool
        public let isThaiOrSEASeries: Bool
        public let isDomesticSeries: Bool
        public let isCheapDomesticWebDrama: Bool
        public let isIdolOrBLFiltered: Bool
        public let isAnimeOrAnimation: Bool
        public let isAnimeExcluded: Bool
        public let isDocumentary: Bool
        public let isSuspiciousPerfectRating: Bool
        public let reasons: [String]
    }

    private struct EvaluatedCandidate {
        let item: EmbyItem
        let libraryId: String?
        let sourceIndex: Int
        let audit: AuditResult
    }

    // MARK: - Public API

    /// Selects up to `maxCount` curated hero items from library shelves and optional top-rated pools.
    public static func selectHeroItems(
        libraryViews: [EmbyItem],
        latestByLibrary: [String: [EmbyItem]],
        extraCandidates: [EmbyItem] = [],
        ratingsByItemId: [String: MultiPlatformRatings] = [:],
        fallbackResumes: [EmbyItem] = [],
        maxCount: Int = 8,
        referenceYear: Int? = nil,
        serverName: String? = nil,
        explicitAnimeMode: Bool? = nil
    ) -> [EmbyItem] {
        guard maxCount > 0 else { return [] }
        let refYear = referenceYear ?? Calendar.current.component(.year, from: Date())
        let allowAnime = isAnimeFocusedServer(
            serverName: serverName,
            libraryViews: libraryViews,
            explicitAnimeMode: explicitAnimeMode
        )

        let viewNameById: [String: String] = Dictionary(
            uniqueKeysWithValues: libraryViews.map { ($0.id, $0.name) }
        )

        var orderedLibraryIds: [String] = libraryViews.map(\.id)
        let knownIds = Set(orderedLibraryIds)
        for extraId in latestByLibrary.keys.sorted() where !knownIds.contains(extraId) {
            orderedLibraryIds.append(extraId)
        }

        var bestById: [String: EvaluatedCandidate] = [:]
        var bestByDedupeKey: [String: EvaluatedCandidate] = [:]
        var seq = 0

        func ingest(_ item: EmbyItem, libraryId: String?, libraryName: String?, libraryRank: Int) {
            if item.isFolder == true && !item.isSeries { return }
            let typeLower = item.type?.lowercased() ?? ""
            if typeLower == "collectionfolder" || typeLower == "folder" || typeLower == "boxset" || typeLower == "musicaudio" {
                return
            }

            let auditResult = audit(
                item,
                libraryName: libraryName,
                referenceYear: refYear,
                libraryRank: libraryRank,
                multiPlatformRatings: ratingsByItemId[item.id],
                allowAnime: allowAnime
            )
            let evaluated = EvaluatedCandidate(
                item: item,
                libraryId: libraryId,
                sourceIndex: seq,
                audit: auditResult
            )
            seq += 1

            if let existing = bestById[item.id], existing.audit.score >= evaluated.audit.score {
                return
            }
            bestById[item.id] = evaluated

            let dedupeKey = normalizedDedupeKey(for: item)
            if let existing = bestByDedupeKey[dedupeKey] {
                if evaluated.audit.score > existing.audit.score {
                    bestByDedupeKey[dedupeKey] = evaluated
                }
            } else {
                bestByDedupeKey[dedupeKey] = evaluated
            }
        }

        for libId in orderedLibraryIds {
            guard let items = latestByLibrary[libId], !items.isEmpty else { continue }
            let libName = viewNameById[libId]
            if !allowAnime && isAnimeLibraryName(libName) { continue }
            for (rank, item) in items.enumerated() {
                ingest(item, libraryId: libId, libraryName: libName, libraryRank: rank)
            }
        }

        for item in extraCandidates {
            let libId = item.parentId
            let libName = libId.flatMap { viewNameById[$0] }
            if !allowAnime && isAnimeLibraryName(libName) { continue }
            ingest(item, libraryId: libId, libraryName: libName, libraryRank: .max)
        }

        let libraryCandidates = Array(bestByDedupeKey.values)
        let isHardExcluded: (EvaluatedCandidate) -> Bool = {
            $0.audit.isCheapDomesticWebDrama || $0.audit.isAnimeExcluded || $0.audit.isIdolOrBLFiltered
        }
        let approved = libraryCandidates
            .filter { !isHardExcluded($0) && !$0.audit.isSuspiciousPerfectRating && $0.audit.score >= 0 }
            .sorted(by: candidateComparator)
        let secondary = libraryCandidates
            .filter { !isHardExcluded($0) && ($0.audit.isSuspiciousPerfectRating || $0.audit.score < 0) }
            .sorted(by: candidateComparator)
        let rejected = libraryCandidates
            .filter { isHardExcluded($0) }
            .sorted(by: candidateComparator)

        var selected: [EmbyItem] = []
        var selectedIds = Set<String>()
        var perLibraryCount: [String: Int] = [:]
        var domesticSeriesCount = 0
        var regionalAsianDramaCount = 0
        var documentaryCount = 0

        let activeLibraryCount = Set(approved.compactMap(\.libraryId)).count
        let perLibrarySoftCap = activeLibraryCount >= 2 ? max(3, maxCount / 2) : maxCount
        let domesticSeriesSoftCap = 1

        // Pass 1: High-quality diverse picks from approved pool (prefer narrative movies/series over documentaries).
        for cand in approved where selected.count < maxCount {
            if cand.audit.isDocumentary { continue }
            if cand.audit.isDomesticSeries && domesticSeriesCount >= domesticSeriesSoftCap { continue }
            if (cand.audit.isKoreanSeries || cand.audit.isThaiOrSEASeries) && regionalAsianDramaCount >= 1 { continue }
            if let libId = cand.libraryId, (perLibraryCount[libId] ?? 0) >= perLibrarySoftCap { continue }
            guard selectedIds.insert(cand.item.id).inserted else { continue }
            selected.append(cand.item)
            if let libId = cand.libraryId { perLibraryCount[libId, default: 0] += 1 }
            if cand.audit.isDomesticSeries { domesticSeriesCount += 1 }
            if cand.audit.isKoreanSeries || cand.audit.isThaiOrSEASeries { regionalAsianDramaCount += 1 }
        }

        // Pass 2: Relax library cap on approved pool (cap documentaries at 1 if narrative candidates are scarce).
        for cand in approved where selected.count < maxCount {
            guard !selectedIds.contains(cand.item.id) else { continue }
            if cand.audit.isDocumentary && documentaryCount >= 1 { continue }
            if cand.audit.isDomesticSeries && domesticSeriesCount >= 2 { continue }
            if (cand.audit.isKoreanSeries || cand.audit.isThaiOrSEASeries) && regionalAsianDramaCount >= 2 { continue }
            selectedIds.insert(cand.item.id)
            selected.append(cand.item)
            if cand.audit.isDocumentary { documentaryCount += 1 }
            if cand.audit.isDomesticSeries { domesticSeriesCount += 1 }
            if cand.audit.isKoreanSeries || cand.audit.isThaiOrSEASeries { regionalAsianDramaCount += 1 }
        }

        // Pass 3: Remaining approved items.
        for cand in approved where selected.count < maxCount {
            guard selectedIds.insert(cand.item.id).inserted else { continue }
            selected.append(cand.item)
        }

        // Pass 4: Non-excluded secondary items.
        for cand in secondary where selected.count < maxCount {
            guard selectedIds.insert(cand.item.id).inserted else { continue }
            selected.append(cand.item)
        }

        // Pass 5: Audited fallback resume items (avoiding excluded cheap/idol/BL/anime items).
        if selected.count < maxCount && !fallbackResumes.isEmpty {
            let evaluatedResumes = fallbackResumes.enumerated().map { idx, item in
                EvaluatedCandidate(
                    item: item,
                    libraryId: nil,
                    sourceIndex: seq + idx,
                    audit: audit(item, libraryName: nil, referenceYear: refYear, allowAnime: allowAnime)
                )
            }
            for cand in evaluatedResumes.filter({ !isHardExcluded($0) }).sorted(by: candidateComparator)
                where selected.count < maxCount {
                guard selectedIds.insert(cand.item.id).inserted else { continue }
                selected.append(cand.item)
            }
        }

        // Pass 6: Last-resort fallback only if the entire server has zero approved/secondary items.
        if selected.isEmpty {
            for cand in rejected where selected.count < maxCount {
                guard selectedIds.insert(cand.item.id).inserted else { continue }
                selected.append(cand.item)
            }
            if selected.isEmpty {
                for item in fallbackResumes where selected.count < maxCount {
                    guard selectedIds.insert(item.id).inserted else { continue }
                    selected.append(item)
                }
            }
        }

        return selected
    }

    /// Evaluates a single `EmbyItem` and returns its hero curation score and audit flags.
    public static func audit(
        _ item: EmbyItem,
        libraryName: String? = nil,
        referenceYear: Int? = nil,
        libraryRank: Int = .max,
        multiPlatformRatings: MultiPlatformRatings? = nil,
        allowAnime: Bool = false
    ) -> AuditResult {
        let refYear = referenceYear ?? Calendar.current.component(.year, from: Date())
        let typeLower = item.type?.lowercased() ?? ""
        let isMovie = typeLower == "movie"
        let isSeries = item.isSeries
        let isEpisode = item.isEpisode

        let critic = item.criticRating ?? 0
        let year = resolvedYear(for: item)
        let age = year.map { max(0, refYear - $0) }
        let libLower = (libraryName ?? "").lowercased()
        let genresLower = (item.genres ?? []).map { $0.lowercased() }

        let isAnime = isAnimeOrAnimation(item, libraryName: libraryName)
        let isAnimeExcluded = isAnime && !allowAnime
        let isDoc = isDocumentary(item, libraryName: libraryName)

        let origin = detectOrigin(
            item: item,
            libraryLower: libLower,
            externalCountries: multiPlatformRatings?.countries
        )
        let isClassicLibrary = classicLibraryKeywords.contains { libLower.contains($0) }

        let isWesternOrigin = (origin == .western)
        let isJapaneseOrigin = (origin == .japanese)
        let isKoreanOrigin = (origin == .korean)
        let isThaiOrigin = (origin == .thaiOrSEA)
        let isDomesticOrigin = (origin == .domestic)

        let isForeignMovie = isMovie && (isWesternOrigin || isJapaneseOrigin || isKoreanOrigin) && !isAnime
        let isForeignSeries = isSeries && (isWesternOrigin || isJapaneseOrigin) && !isAnime
        let isKoreanSeries = isSeries && isKoreanOrigin && !isAnime
        let isThaiOrSEASeries = isSeries && isThaiOrigin && !isAnime
        let isDomesticSeries = isSeries && isDomesticOrigin && !isAnime

        let biasProfile: RatingBiasProfile = {
            if isAnime { return .anime }
            if isThaiOrigin { return .thaiOrSEADrama }
            if isKoreanSeries { return .koreanDrama }
            if isDomesticSeries { return .domesticDrama }
            return .standard
        }()

        let hasImdbProvider = item.providerIds?.keys.contains(where: { $0.lowercased() == "imdb" }) == true
            || !(multiPlatformRatings?.imdbId ?? "").isEmpty
        let mpEval = MultiPlatformRatings.evaluate(
            multiPlatformRatings,
            fallbackTMDB: item.communityRating,
            fallbackCriticRating: item.criticRating,
            hasImdbProviderId: hasImdbProvider,
            isDomesticSeries: isDomesticSeries,
            isMovie: isMovie,
            isAnime: isAnime,
            biasProfile: biasProfile
        )
        let rating = mpEval.weightedScore ?? 0
        let trustAcclaimTier = !mpEval.isSuspiciousPerfectRating

        var score: Double = mpEval.consensusDelta
        var reasons: [String] = []
        if mpEval.consensusDelta != 0 {
            reasons.append("multi_platform(\(mpEval.professionalCriticCount)critic/\(mpEval.authoritativePlatformCount)auth):\(Int(mpEval.consensusDelta))")
        }
        if mpEval.isSuspiciousPerfectRating {
            reasons.append("suspicious_perfect_rating_unverified")
        }
        if isAnimeExcluded {
            score -= 120
            reasons.append("anime_excluded_non_anime_home:-120")
        }
        var isClassicMovie = false
        var isCheapDomesticWebDrama = false
        var isIdolOrBLFiltered = false

        // 1. Media Type & Region-Tiered Weighting
        if isAnime {
            if allowAnime {
                score += 12
                if trustAcclaimTier && rating >= 7.8 {
                    score += 18
                    reasons.append("anime_acclaimed:+18")
                } else if trustAcclaimTier && rating >= 7.2 {
                    score += 10
                    reasons.append("anime_good:+10")
                }
            }
        } else if isDoc {
            // Documentaries & docuseries are strongly downranked relative to narrative movies and drama series.
            score -= 38
            reasons.append("documentary_downrank:-38")
            if trustAcclaimTier && mpEval.hasStrongCriticEndorsement && rating >= 8.2 {
                score += 12
                reasons.append("documentary_critic_acclaimed:+12")
            }
        } else if isMovie {
            score += 34
            reasons.append("movie:+34")

            if let age, age >= 5 {
                if trustAcclaimTier && rating >= 8.0 {
                    isClassicMovie = true
                    score += 42
                    reasons.append("classic_movie_acclaimed:+42")
                } else if trustAcclaimTier && rating >= 7.4 {
                    isClassicMovie = true
                    score += 32
                    reasons.append("classic_movie_high:+32")
                } else if age >= 10 && trustAcclaimTier && rating >= 6.8 {
                    isClassicMovie = true
                    score += 24
                    reasons.append("classic_movie_catalog:+24")
                } else if isClassicLibrary && trustAcclaimTier && (rating == 0 || rating >= 6.5) {
                    isClassicMovie = true
                    score += 24
                    reasons.append("classic_movie_library:+24")
                }
            } else if trustAcclaimTier && rating >= 7.8 {
                score += 28
                reasons.append("modern_movie_acclaimed:+28")
            } else if trustAcclaimTier && rating >= 7.0 {
                score += 18
                reasons.append("modern_movie_good:+18")
            }

            if let age, age <= 2, trustAcclaimTier, rating >= 7.2 {
                score += 10
                reasons.append("hot_recent_movie:+10")
            }

            if isWesternOrigin {
                score += 18
                reasons.append("western_movie:+18")
            } else if isJapaneseOrigin {
                score += 8
                reasons.append("japanese_movie:+8")
            } else if isThaiOrigin && !mpEval.hasStrongCriticEndorsement {
                score -= 14
                reasons.append("thai_movie_scrutiny:-14")
            }
            if isClassicLibrary {
                score += 12
                reasons.append("classic_library:+12")
            }
        } else if isSeries && isWesternOrigin {
            score += 26
            reasons.append("western_series:+26")

            if trustAcclaimTier && rating >= 8.2 {
                score += 26
                reasons.append("western_series_acclaimed:+26")
            } else if trustAcclaimTier && rating >= 7.6 {
                score += 18
                reasons.append("western_series_high:+18")
            } else if trustAcclaimTier && rating >= 7.0 {
                score += 10
                reasons.append("western_series_good:+10")
            } else if rating > 0 && rating < 6.0 {
                score -= 14
                reasons.append("western_series_low_rating:-14")
            }

            if let age, age >= 5, trustAcclaimTier, rating >= 7.6 {
                score += 12
                reasons.append("classic_western_series:+12")
            } else if let age, age <= 1 {
                if trustAcclaimTier && rating >= 7.5 {
                    score += 20
                    reasons.append("hot_recent_western_series_high:+20")
                } else if trustAcclaimTier && (rating >= 6.8 || rating == 0) {
                    score += 14
                    reasons.append("hot_recent_western_series:+14")
                }
            } else if let age, age <= 3, trustAcclaimTier, rating >= 7.2 {
                score += 12
                reasons.append("recent_western_series:+12")
            }

            if item.status?.lowercased() == "continuing", trustAcclaimTier, (rating == 0 || rating >= 6.8) {
                score += 8
                reasons.append("continuing_western_series:+8")
            }
            if libraryRank < 5, (age ?? 99) <= 2, trustAcclaimTier, (rating == 0 || rating >= 6.8) {
                score += 8
                reasons.append("fresh_hot_western_series:+8")
            }
            if (item.childCount ?? 0) >= 2 && trustAcclaimTier && rating >= 7.0 {
                score += 6
                reasons.append("multi_season_western_series:+6")
            }
        } else if isSeries && isJapaneseOrigin {
            // Live-action Japanese series: moderate prestige tier without blind Western hype boost.
            score += 10
            reasons.append("japanese_series:+10")
            if trustAcclaimTier && rating >= 8.0 {
                score += 16
                reasons.append("japanese_series_acclaimed:+16")
            } else if trustAcclaimTier && rating >= 7.4 {
                score += 8
                reasons.append("japanese_series_good:+8")
            } else if rating > 0 && rating < 6.5 {
                score -= 12
                reasons.append("japanese_series_low:-12")
            }
        } else if isKoreanSeries {
            // Korean series: stripped of Western boost; heavily scrutinized unless critic-verified non-idol prestige.
            score -= 18
            reasons.append("korean_series_scrutiny:-18")
            if trustAcclaimTier && mpEval.hasStrongCriticEndorsement && rating >= 7.8 {
                score += 18
                reasons.append("korean_series_critic_verified:+18")
            } else if trustAcclaimTier && rating >= 7.6 && mpEval.imdbVotes >= 30_000 {
                score += 10
                reasons.append("korean_series_global_hit:+10")
            } else if rating <= 0 || rating < 7.0 {
                score -= 16
                reasons.append("korean_series_weak_effective_rating:-16")
            }
        } else if isThaiOrSEASeries {
            // Thai / SEA series: heaviest fandom-inflation scrutiny; not hard-banned, but requires extraordinary critic backing.
            score -= 32
            reasons.append("thai_series_heavy_scrutiny:-32")
            if trustAcclaimTier && mpEval.hasStrongCriticEndorsement && rating >= 8.0 {
                score += 16
                reasons.append("thai_series_critic_verified:+16")
            } else if rating <= 0 || rating < 7.2 {
                score -= 18
                reasons.append("thai_series_weak_effective_rating:-18")
            }
        } else if isSeries {
            if isDomesticSeries {
                score -= 14
                reasons.append("domestic_series_scrutiny:-14")
            } else {
                score += 4
                reasons.append("neutral_series:+4")
            }
        } else if isEpisode {
            score -= 35
            reasons.append("episode_penalty:-35")
        }

        // 2. Universal Idol / BL / Romance / Soap Fandom Filter (applies to Korean, Thai/SEA, Japanese, and ambiguous series)
        let idolSignals = hasIdolBLOrRomanceSignals(item: item, libraryLower: libLower, genresLower: genresLower)
        if !mpEval.hasStrongCriticEndorsement {
            if idolSignals.hasExplicitBLOrFandom {
                score -= 65
                isIdolOrBLFiltered = true
                reasons.append("bl_idol_fandom_filtered:-65")
            } else if isThaiOrSEASeries && (idolSignals.hasIdolRomanceGenre || rating < 7.5) {
                score -= 52
                isIdolOrBLFiltered = true
                reasons.append("thai_idol_romance_filtered:-52")
            } else if isKoreanSeries && idolSignals.hasIdolRomanceGenre {
                score -= 48
                isIdolOrBLFiltered = true
                reasons.append("korean_idol_romance_filtered:-48")
            } else if isSeries && isJapaneseOrigin && idolSignals.hasIdolRomanceGenre && rating < 7.6 {
                score -= 22
                reasons.append("japanese_romance_penalty:-22")
            }
        }

        // 3. Cheap Domestic Web Drama & Micro-Drama Audit
        let cheapHitCount = countCheapWebDramaSignals(item: item, libraryLower: libLower, genresLower: genresLower)
        if cheapHitCount > 0 {
            let keywordPenalty = min(105.0, 65.0 + Double(cheapHitCount - 1) * 20.0)
            score -= keywordPenalty
            isCheapDomesticWebDrama = true
            reasons.append("cheap_web_drama_keywords(\(cheapHitCount)):-\(Int(keywordPenalty))")
        }

        if isDomesticSeries {
            if let ticks = item.runTimeTicks, ticks > 0, ticks < shortEpisodeTicksThreshold {
                score -= 45
                isCheapDomesticWebDrama = true
                reasons.append("domestic_short_episode_runtime:-45")
            }
            if rating <= 0 {
                score -= 36
                isCheapDomesticWebDrama = true
                reasons.append("domestic_series_unrated:-36")
            } else if rating < 6.5 {
                score -= 40
                isCheapDomesticWebDrama = true
                reasons.append("domestic_series_low_rating:-40")
            } else if rating < 7.3 {
                score -= 24
                reasons.append("domestic_series_mediocre_rating:-24")
            } else if rating < 8.0 {
                score -= 8
                reasons.append("domestic_series_moderate_rating:-8")
            } else {
                score += 6
                reasons.append("domestic_series_acclaimed:+6")
            }

            if idolSignals.hasIdolRomanceGenre && rating < 7.8 {
                score -= 18
                if rating < 7.0 { isCheapDomesticWebDrama = true }
                reasons.append("domestic_idol_genre_penalty:-18")
            }
            if let age, age <= 2, (item.childCount ?? 1) <= 1, rating < 7.6 {
                score -= 14
                reasons.append("domestic_recent_single_season:-14")
            }
            if cjkCharacterCount(item.name) >= 9 && rating < 7.6 {
                score -= 12
                reasons.append("domestic_long_trope_title:-12")
            }
        }

        // 4. Universal Quality & Visual Polish Signals
        let hasBackdrop = hasWideBackdrop(item)
        let hasAnyArtwork = hasBackdrop || hasPosterOrThumb(item)
        if hasBackdrop {
            score += 14
            reasons.append("has_backdrop:+14")
        } else if hasAnyArtwork {
            score -= 18
            reasons.append("no_backdrop:-18")
            if isDomesticSeries || isKoreanSeries || isThaiOrSEASeries {
                score -= 16
                reasons.append("regional_series_no_backdrop:-16")
            }
        } else {
            score -= 40
            reasons.append("no_artwork:-40")
        }

        if hasClearLogo(item) {
            score += 4
            reasons.append("has_logo:+4")
        }

        if let overview = item.overview?.trimmingCharacters(in: .whitespacesAndNewlines), overview.count >= 20 {
            score += 3
            reasons.append("has_overview:+3")
        }

        if rating > 0 && !mpEval.isSuspiciousPerfectRating {
            let cappedRating = mpEval.isStrongConsensus ? min(rating, 9.3) : min(rating, 8.9)
            let ratingSlope = min(14.0, max(-24.0, (cappedRating - 6.5) * 4.5))
            score += ratingSlope
        }

        if critic >= 80 {
            score += 8
            reasons.append("critic_acclaimed:+8")
        } else if critic >= 65 {
            score += 4
            reasons.append("critic_good:+4")
        }

        let hasPrestigeGenre = genresLower.contains { g in
            prestigeGenres.contains { g.contains($0) }
        }
        if hasPrestigeGenre && (isMovie || isForeignSeries || mpEval.hasStrongCriticEndorsement || rating >= 7.8) {
            score += 5
            reasons.append("prestige_genre:+5")
        }

        let isVariety = genresLower.contains { g in
            varietyGenresAndKeywords.contains { g.contains($0) }
        } || varietyGenresAndKeywords.contains { libLower.contains($0) }
        if isVariety {
            score -= 22
            reasons.append("variety_penalty:-22")
        }

        if item.userData?.played != true {
            score += 3
        }

        return AuditResult(
            score: score,
            effectiveRating: rating,
            isClassicMovie: isClassicMovie,
            isForeignSeries: isForeignSeries,
            isForeignMovie: isForeignMovie,
            isKoreanSeries: isKoreanSeries,
            isThaiOrSEASeries: isThaiOrSEASeries,
            isDomesticSeries: isDomesticSeries,
            isCheapDomesticWebDrama: isCheapDomesticWebDrama,
            isIdolOrBLFiltered: isIdolOrBLFiltered,
            isAnimeOrAnimation: isAnime,
            isAnimeExcluded: isAnimeExcluded,
            isDocumentary: isDoc,
            isSuspiciousPerfectRating: mpEval.isSuspiciousPerfectRating,
            reasons: reasons
        )
    }

    // MARK: - Helpers

    private static func candidateComparator(_ lhs: EvaluatedCandidate, _ rhs: EvaluatedCandidate) -> Bool {
        if lhs.audit.score != rhs.audit.score {
            return lhs.audit.score > rhs.audit.score
        }
        if lhs.audit.effectiveRating != rhs.audit.effectiveRating {
            return lhs.audit.effectiveRating > rhs.audit.effectiveRating
        }
        if lhs.sourceIndex != rhs.sourceIndex {
            return lhs.sourceIndex < rhs.sourceIndex
        }
        return lhs.item.id < rhs.item.id
    }
}

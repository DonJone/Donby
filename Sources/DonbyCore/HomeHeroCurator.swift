import Foundation

/// Curates the home hero carousel (`carouselItems`) from library candidates.
///
/// Ranking priorities:
/// 1. Boosts classic movies and acclaimed foreign TV series (US/UK/EU/JP/KR/etc.).
/// 2. Audits and strongly downranks / filters out cheap domestic web dramas and micro-dramas.
/// 3. Operates strictly on canonical library items (never on extension-injected promotional/hot feeds).
public enum HomeHeroCurator {
    public struct AuditResult: Sendable, Equatable {
        public let score: Double
        public let isClassicMovie: Bool
        public let isForeignSeries: Bool
        public let isForeignMovie: Bool
        public let isDomesticSeries: Bool
        public let isCheapDomesticWebDrama: Bool
        public let reasons: [String]
    }

    private enum OriginClass {
        case foreign
        case domestic
        case unknown
    }

    private struct EvaluatedCandidate {
        let item: EmbyItem
        let libraryId: String?
        let sourceIndex: Int
        let audit: AuditResult
    }

    // MARK: - Keyword Tables

    private static let foreignLibraryKeywords: [String] = [
        "欧美", "美剧", "英剧", "日剧", "韩剧", "日韩", "海外", "外剧", "外语",
        "泰剧", "欧洲", "好莱坞", "hollywood", "foreign", "western",
        "korean", "japanese", "kdrama", "jdrama", "us/uk", "uk/us", "anime", "日漫", "番剧"
    ]

    private static let domesticLibraryKeywords: [String] = [
        "国产", "华语", "大陆", "内地", "国剧", "短剧", "微短剧", "网剧",
        "国产剧", "内地剧", "中文剧", "国漫", "港台"
    ]

    private static let classicLibraryKeywords: [String] = [
        "经典", "classic", "imdb", "top250", "top 250", "豆瓣", "高分",
        "奥斯卡", "oscar", "影史", "masterpiece", "criterion", "必看"
    ]

    private static let cheapWebDramaKeywords: [String] = [
        "短剧", "微短剧", "竖屏", "爽剧", "霸总", "赘婿", "战神", "龙王", "神医",
        "闪婚", "甜宠", "虐恋", "重生之", "穿书", "攻略", "娇妻", "萌宝", "夫人她",
        "离婚后", "替嫁", "总裁", "王爷", "皇叔", "偏宠", "独宠", "诱哄", "疯批",
        "白月光", "黑莲花", "女配", "反派", "下山", "退婚", "签到", "系统",
        "漫剧", "动态漫", "有声漫", "沙雕动画", "网大", "网络大电影", "网剧",
        "一口气看完", "全集解说", "逆袭", "千金", "少爷", "大小姐", "小娇妻",
        "真千金", "假千金", "闪婚后", "带球跑", "追妻", "火葬场", "团宠", "萌娃"
    ]

    private static let cheapWebDramaStudios: [String] = [
        "横店", "快手", "抖音", "红果", "番茄", "九州", "点众", "容量", "麦芽", "微短剧"
    ]

    private static let domesticIdolGenres: [String] = [
        "古偶", "仙侠", "甜宠", "都市", "爱情", "romance", "soap", "肥皂剧", "言情", "偶像"
    ]

    private static let prestigeGenres: [String] = [
        "剧情", "drama", "科幻", "sci-fi", "science fiction", "悬疑", "mystery",
        "惊悚", "thriller", "犯罪", "crime", "战争", "war", "历史", "history",
        "传记", "biography", "纪录", "documentary", "冒险", "adventure", "奇幻", "fantasy"
    ]

    private static let varietyGenresAndKeywords: [String] = [
        "综艺", "真人秀", "脱口秀", "晚会", "演唱会", "reality", "talk", "talk show", "news", "game show"
    ]

    /// 22 minutes in Emby ticks (1 tick = 100ns).
    private static let shortEpisodeTicksThreshold: Int64 = 22 * 60 * 10_000_000

    // MARK: - Public API

    /// Selects up to `maxCount` curated hero items from library shelves.
    public static func selectHeroItems(
        libraryViews: [EmbyItem],
        latestByLibrary: [String: [EmbyItem]],
        fallbackResumes: [EmbyItem] = [],
        maxCount: Int = 8,
        referenceYear: Int? = nil
    ) -> [EmbyItem] {
        guard maxCount > 0 else { return [] }
        let refYear = referenceYear ?? Calendar.current.component(.year, from: Date())

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
            // Skip pure folder/collection entries that are not playable movies or series.
            if item.isFolder == true && !item.isSeries { return }
            let typeLower = item.type?.lowercased() ?? ""
            if typeLower == "collectionfolder" || typeLower == "folder" || typeLower == "boxset" || typeLower == "musicaudio" {
                return
            }

            let auditResult = audit(item, libraryName: libraryName, referenceYear: refYear, libraryRank: libraryRank)
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
            for (rank, item) in items.enumerated() {
                ingest(item, libraryId: libId, libraryName: libName, libraryRank: rank)
            }
        }

        // Deduplicated candidate pool from libraries.
        let libraryCandidates = Array(bestByDedupeKey.values)
        let approved = libraryCandidates
            .filter { !$0.audit.isCheapDomesticWebDrama && $0.audit.score >= 0 }
            .sorted(by: candidateComparator)
        let secondary = libraryCandidates
            .filter { !$0.audit.isCheapDomesticWebDrama && $0.audit.score < 0 }
            .sorted(by: candidateComparator)
        let rejected = libraryCandidates
            .filter { $0.audit.isCheapDomesticWebDrama }
            .sorted(by: candidateComparator)

        var selected: [EmbyItem] = []
        var selectedIds = Set<String>()
        var perLibraryCount: [String: Int] = [:]
        var domesticSeriesCount = 0

        let activeLibraryCount = Set(approved.compactMap(\.libraryId)).count
        let perLibrarySoftCap = activeLibraryCount >= 2 ? max(3, maxCount / 2) : maxCount
        let domesticSeriesSoftCap = 1

        // Pass 1: High-quality diverse picks from approved pool.
        for cand in approved where selected.count < maxCount {
            if cand.audit.isDomesticSeries && domesticSeriesCount >= domesticSeriesSoftCap {
                continue
            }
            if let libId = cand.libraryId, (perLibraryCount[libId] ?? 0) >= perLibrarySoftCap {
                continue
            }
            guard selectedIds.insert(cand.item.id).inserted else { continue }
            selected.append(cand.item)
            if let libId = cand.libraryId { perLibraryCount[libId, default: 0] += 1 }
            if cand.audit.isDomesticSeries { domesticSeriesCount += 1 }
        }

        // Pass 2: Relax library cap on approved pool (keep domestic series capped at 2 if possible).
        for cand in approved where selected.count < maxCount {
            guard !selectedIds.contains(cand.item.id) else { continue }
            if cand.audit.isDomesticSeries && domesticSeriesCount >= 2 {
                continue
            }
            selectedIds.insert(cand.item.id)
            selected.append(cand.item)
            if cand.audit.isDomesticSeries { domesticSeriesCount += 1 }
        }

        // Pass 3: Remaining approved items (including >2 acclaimed domestic series if needed).
        for cand in approved where selected.count < maxCount {
            guard selectedIds.insert(cand.item.id).inserted else { continue }
            selected.append(cand.item)
        }

        // Pass 4: Non-rejected secondary items.
        for cand in secondary where selected.count < maxCount {
            guard selectedIds.insert(cand.item.id).inserted else { continue }
            selected.append(cand.item)
        }

        // Pass 5: Audited fallback resume items (avoiding cheap domestic web dramas).
        if selected.count < maxCount && !fallbackResumes.isEmpty {
            let evaluatedResumes = fallbackResumes.enumerated().map { idx, item in
                EvaluatedCandidate(
                    item: item,
                    libraryId: nil,
                    sourceIndex: seq + idx,
                    audit: audit(item, libraryName: nil, referenceYear: refYear)
                )
            }
            for cand in evaluatedResumes.filter({ !$0.audit.isCheapDomesticWebDrama }).sorted(by: candidateComparator)
                where selected.count < maxCount {
                guard selectedIds.insert(cand.item.id).inserted else { continue }
                selected.append(cand.item)
            }
        }

        // Pass 6: Last-resort fallback only if the entire library has almost no approved items.
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
        libraryRank: Int = .max
    ) -> AuditResult {
        let refYear = referenceYear ?? Calendar.current.component(.year, from: Date())
        let typeLower = item.type?.lowercased() ?? ""
        let isMovie = typeLower == "movie"
        let isSeries = item.isSeries
        let isEpisode = item.isEpisode

        let rating = item.communityRating ?? 0
        let critic = item.criticRating ?? 0
        let year = resolvedYear(for: item)
        let age = year.map { max(0, refYear - $0) }
        let libLower = (libraryName ?? "").lowercased()
        let genresLower = (item.genres ?? []).map { $0.lowercased() }

        let origin = detectOrigin(item: item, libraryLower: libLower)
        let isForeignOrigin = (origin == .foreign)
        let isDomesticOrigin = (origin == .domestic)
        let isClassicLibrary = classicLibraryKeywords.contains { libLower.contains($0) }

        let isForeignMovie = isMovie && isForeignOrigin
        let isForeignSeries = isSeries && isForeignOrigin
        let isDomesticSeries = isSeries && isDomesticOrigin

        var score: Double = 0
        var reasons: [String] = []
        var isClassicMovie = false
        var isCheapDomesticWebDrama = false

        // 1. Media Type & Classic / Foreign Weighting
        if isMovie {
            score += 18
            reasons.append("movie:+18")

            if let age, age >= 5 {
                if rating >= 8.0 {
                    isClassicMovie = true
                    score += 36
                    reasons.append("classic_movie_acclaimed:+36")
                } else if rating >= 7.4 {
                    isClassicMovie = true
                    score += 26
                    reasons.append("classic_movie_high:+26")
                } else if age >= 10 && rating >= 6.8 {
                    isClassicMovie = true
                    score += 18
                    reasons.append("classic_movie_catalog:+18")
                } else if isClassicLibrary && (rating == 0 || rating >= 6.5) {
                    isClassicMovie = true
                    score += 20
                    reasons.append("classic_movie_library:+20")
                }
            } else if rating >= 7.8 {
                score += 16
                reasons.append("modern_movie_acclaimed:+16")
            } else if rating >= 7.0 {
                score += 8
                reasons.append("modern_movie_good:+8")
            }

            if isForeignMovie {
                score += 12
                reasons.append("foreign_movie:+12")
            }
            if isClassicLibrary {
                score += 12
                reasons.append("classic_library:+12")
            }
        } else if isForeignSeries {
            score += 26
            reasons.append("foreign_series:+26")

            if rating >= 8.2 {
                score += 26
                reasons.append("foreign_series_acclaimed:+26")
            } else if rating >= 7.6 {
                score += 18
                reasons.append("foreign_series_high:+18")
            } else if rating >= 7.0 {
                score += 10
                reasons.append("foreign_series_good:+10")
            } else if rating > 0 && rating < 6.0 {
                score -= 14
                reasons.append("foreign_series_low_rating:-14")
            }

            if let age, age >= 5, rating >= 7.6 {
                score += 12
                reasons.append("classic_foreign_series:+12")
            } else if let age, age <= 1 {
                if rating >= 7.5 {
                    score += 20
                    reasons.append("hot_recent_foreign_series_high:+20")
                } else if rating >= 6.8 || rating == 0 {
                    score += 14
                    reasons.append("hot_recent_foreign_series:+14")
                }
            } else if let age, age <= 3, rating >= 7.2 {
                score += 12
                reasons.append("recent_foreign_series:+12")
            }

            if item.status?.lowercased() == "continuing", (rating == 0 || rating >= 6.8) {
                score += 8
                reasons.append("continuing_foreign_series:+8")
            }
            if libraryRank < 5, (age ?? 99) <= 2, (rating == 0 || rating >= 6.8) {
                score += 8
                reasons.append("fresh_hot_foreign_series:+8")
            }
            if (item.childCount ?? 0) >= 2 && rating >= 7.0 {
                score += 6
                reasons.append("multi_season_foreign_series:+6")
            }
        } else if isSeries {
            // Domestic or unknown-origin series
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

        // 2. Cheap Domestic Web Drama & Micro-Drama Audit
        let cheapHitCount = countCheapWebDramaSignals(item: item, libraryLower: libLower, genresLower: genresLower)
        if cheapHitCount > 0 {
            let keywordPenalty = min(105.0, 65.0 + Double(cheapHitCount - 1) * 20.0)
            score -= keywordPenalty
            isCheapDomesticWebDrama = true
            reasons.append("cheap_web_drama_keywords(\(cheapHitCount)):-\(Int(keywordPenalty))")
        }

        if isDomesticSeries {
            // Short runtime per episode (< 22 min) is a strong micro-drama / cheap web-drama indicator.
            if let ticks = item.runTimeTicks, ticks > 0, ticks < shortEpisodeTicksThreshold {
                score -= 45
                isCheapDomesticWebDrama = true
                reasons.append("domestic_short_episode_runtime:-45")
            }

            // Strict rating audit for domestic series.
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

            // Idol / romance / soap genre scrutiny when not genuinely acclaimed.
            let hasIdolGenre = genresLower.contains { g in
                domesticIdolGenres.contains { g.contains($0) }
            }
            if hasIdolGenre && rating < 7.8 {
                score -= 18
                if rating < 7.0 { isCheapDomesticWebDrama = true }
                reasons.append("domestic_idol_genre_penalty:-18")
            }

            // Recent single-season domestic series without strong acclaim.
            if let age, age <= 2, (item.childCount ?? 1) <= 1, rating < 7.6 {
                score -= 14
                reasons.append("domestic_recent_single_season:-14")
            }

            // Cliché long Chinese title without strong rating.
            if cjkCharacterCount(item.name) >= 9 && rating < 7.6 {
                score -= 12
                reasons.append("domestic_long_trope_title:-12")
            }
        }

        // 3. Universal Quality & Visual Polish Signals
        let hasBackdrop = hasWideBackdrop(item)
        let hasAnyArtwork = hasBackdrop || hasPosterOrThumb(item)
        if hasBackdrop {
            score += 14
            reasons.append("has_backdrop:+14")
        } else if hasAnyArtwork {
            score -= 18
            reasons.append("no_backdrop:-18")
            if isDomesticSeries {
                score -= 16
                reasons.append("domestic_series_no_backdrop:-16")
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

        if rating > 0 {
            let ratingSlope = min(18.0, max(-24.0, (rating - 6.5) * 5.0))
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
        if hasPrestigeGenre && (isMovie || isForeignSeries || rating >= 7.8) {
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
            isClassicMovie: isClassicMovie,
            isForeignSeries: isForeignSeries,
            isForeignMovie: isForeignMovie,
            isDomesticSeries: isDomesticSeries,
            isCheapDomesticWebDrama: isCheapDomesticWebDrama,
            reasons: reasons
        )
    }

    // MARK: - Helpers

    private static func candidateComparator(_ lhs: EvaluatedCandidate, _ rhs: EvaluatedCandidate) -> Bool {
        if lhs.audit.score != rhs.audit.score {
            return lhs.audit.score > rhs.audit.score
        }
        let lRating = lhs.item.communityRating ?? 0
        let rRating = rhs.item.communityRating ?? 0
        if lRating != rRating {
            return lRating > rRating
        }
        if lhs.sourceIndex != rhs.sourceIndex {
            return lhs.sourceIndex < rhs.sourceIndex
        }
        return lhs.item.id < rhs.item.id
    }

    private static func normalizedDedupeKey(for item: EmbyItem) -> String {
        let cleanName = item.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let year = resolvedYear(for: item) ?? 0
        let kind = item.isSeries ? "s" : (item.type?.lowercased() ?? "m")
        return "\(kind)|\(cleanName)|\(year)"
    }

    private static func resolvedYear(for item: EmbyItem) -> Int? {
        if let y = item.productionYear, y >= 1900 && y <= 2100 {
            return y
        }
        if let premiere = item.premiereDate, premiere.count >= 4,
           let y = Int(premiere.prefix(4)), y >= 1900 && y <= 2100 {
            return y
        }
        return nil
    }

    private static func detectOrigin(item: EmbyItem, libraryLower: String) -> OriginClass {
        let libIsForeign = foreignLibraryKeywords.contains { libraryLower.contains($0) }
        let libIsDomestic = domesticLibraryKeywords.contains { libraryLower.contains($0) }

        if let orig = item.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !orig.isEmpty {
            let origHasForeign = containsForeignScript(orig)
            let origHasCJK = containsCJK(orig)
            if origHasForeign && !origHasCJK {
                return .foreign
            }
            if origHasForeign && origHasCJK {
                // Mixed Japanese (Kanji + Kana) or foreign title with CJK subtitle -> foreign if Kana/Hangul present.
                if containsKanaOrHangul(orig) || libIsForeign {
                    return .foreign
                }
            }
            if origHasCJK && !origHasForeign {
                return libIsForeign ? .foreign : .domestic
            }
        }

        if libIsForeign && !libIsDomestic {
            return .foreign
        }
        if libIsDomestic && !libIsForeign {
            return .domestic
        }

        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsForeignScript(name) && !containsCJK(name) {
            return .foreign
        }
        if containsCJK(name) && item.isSeries {
            // Without foreign originalTitle or foreign library context, CJK-only series defaults to domestic scrutiny.
            return .domestic
        }
        return .unknown
    }

    private static func countCheapWebDramaSignals(
        item: EmbyItem,
        libraryLower: String,
        genresLower: [String]
    ) -> Int {
        var hits = 0
        let nameLower = item.name.lowercased()
        let taglineLower = (item.taglines ?? []).joined(separator: " ").lowercased()
        let overviewPrefix = String((item.overview ?? "").prefix(160)).lowercased()
        let studioLower = (item.studios ?? []).compactMap { $0.name?.lowercased() }.joined(separator: " ")

        for kw in cheapWebDramaKeywords {
            if nameLower.contains(kw) || libraryLower.contains(kw) || genresLower.contains(where: { $0.contains(kw) }) {
                hits += 1
            } else if taglineLower.contains(kw) || overviewPrefix.contains(kw) {
                hits += 1
            }
        }

        if !studioLower.isEmpty {
            for studio in cheapWebDramaStudios where studioLower.contains(studio) {
                hits += 1
            }
        }

        return hits
    }

    private static func hasWideBackdrop(_ item: EmbyItem) -> Bool {
        if let uhdBackdrop = item.uhdBackdropURL, !uhdBackdrop.isEmpty { return true }
        if let tags = item.backdropImageTags, !tags.isEmpty { return true }
        if let parentTags = item.parentBackdropImageTags, !parentTags.isEmpty { return true }
        if let thumb = item.uhdThumbURL, !thumb.isEmpty { return true }
        if let thumbTag = item.imageTags?["Thumb"], !thumbTag.isEmpty { return true }
        return false
    }

    private static func hasPosterOrThumb(_ item: EmbyItem) -> Bool {
        if let uhdPoster = item.uhdPosterURL, !uhdPoster.isEmpty { return true }
        if let primary = item.imageTags?["Primary"], !primary.isEmpty { return true }
        return false
    }

    private static func hasClearLogo(_ item: EmbyItem) -> Bool {
        if let uhdLogo = item.uhdLogoURL, !uhdLogo.isEmpty { return true }
        if let logo = item.imageTags?["Logo"], !logo.isEmpty { return true }
        return false
    }

    private static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    private static func cjkCharacterCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                count += 1
            }
        }
        return count
    }

    private static func containsKanaOrHangul(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) {
                return true
            }
        }
        return false
    }

    private static func containsForeignScript(_ text: String) -> Bool {
        if containsKanaOrHangul(text) { return true }
        var latinLetters = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Cyrillic, Greek, Arabic, Thai, Devanagari, Latin Extended
            if (0x0400...0x04FF).contains(v)
                || (0x0370...0x03FF).contains(v)
                || (0x0600...0x06FF).contains(v)
                || (0x0E00...0x0E7F).contains(v)
                || (0x0900...0x097F).contains(v)
                || (0x00C0...0x024F).contains(v) {
                return true
            }
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                latinLetters += 1
            }
        }
        guard latinLetters >= 2 else { return false }
        // Ignore pure technical / season / Roman numeral tokens like "4K", "HD", "S01", "TV", "II", "III".
        let stripped = text
            .replacingOccurrences(of: #"(?i)\b(4k|8k|hd|uhd|hdr|s\d{1,2}|e\d{1,3}|tv|ova|oad|sp|ii|iii|iv|vi|vii|viii|ix|x)\b"#, with: "", options: .regularExpression)
        var meaningfulLatin = 0
        for scalar in stripped.unicodeScalars {
            let v = scalar.value
            if (0x0041...0x005A).contains(v) || (0x0061...0x007A).contains(v) {
                meaningfulLatin += 1
                if meaningfulLatin >= 2 { return true }
            }
        }
        return false
    }
}

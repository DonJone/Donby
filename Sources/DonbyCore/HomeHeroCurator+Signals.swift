import Foundation

extension HomeHeroCurator {
    enum OriginClass {
        case foreign
        case domestic
        case unknown
    }

    // MARK: - Keyword Tables

    static let foreignLibraryKeywords: [String] = [
        "欧美", "美剧", "英剧", "日剧", "韩剧", "日韩", "海外", "外剧", "外语",
        "泰剧", "欧洲", "好莱坞", "hollywood", "foreign", "western",
        "korean", "japanese", "kdrama", "jdrama", "us/uk", "uk/us"
    ]

    static let domesticLibraryKeywords: [String] = [
        "国产", "华语", "大陆", "内地", "国剧", "短剧", "微短剧", "网剧",
        "国产剧", "内地剧", "中文剧", "港台"
    ]

    static let animeLibraryKeywords: [String] = [
        "动漫", "动画", "番剧", "新番", "日漫", "国漫", "里番", "动画片", "动画电影",
        "二次元", "剧场版动画", "anime", "animation", "cartoon", "donghua", "bangumi", "acg"
    ]

    static let animeServerKeywords: [String] = [
        "动漫", "动画", "番剧", "二次元", "anime", "bangumi", "acg", "次元", "萌番", "新番", "日漫", "国漫"
    ]

    static let animeGenreKeywords: [String] = [
        "动画", "动漫", "animation", "anime", "cartoon", "儿童", "kids"
    ]

    static let animeStudioKeywords: [String] = [
        "animation", "anime", "动画", "动漫", "mappa", "ufotable", "kyoto animation",
        "a-1 pictures", "wit studio", "cloverworks", "bones", "madhouse", "production i.g",
        "toei", "sunrise", "studio ghibli", "shaft", "trigger", "comix wave", "aniplex",
        "kodansha", "shueisha", "玄机", "绘梦", "追光", "彩条屋", "若森", "bilibili", "腾讯动漫"
    ]

    static let animeTitleKeywords: [String] = [
        "番剧", "新番", "剧场版", "ova", "oad", "sp特典", "异世界", "转生", "动态漫", "漫剧", "沙雕动画"
    ]

    static let classicLibraryKeywords: [String] = [
        "经典", "classic", "imdb", "top250", "top 250", "豆瓣", "高分",
        "奥斯卡", "oscar", "影史", "masterpiece", "criterion", "必看"
    ]

    static let cheapWebDramaKeywords: [String] = [
        "短剧", "微短剧", "竖屏", "爽剧", "霸总", "赘婿", "战神", "龙王", "神医",
        "闪婚", "甜宠", "虐恋", "重生之", "穿书", "攻略", "娇妻", "萌宝", "夫人她",
        "离婚后", "替嫁", "总裁", "王爷", "皇叔", "偏宠", "独宠", "诱哄", "疯批",
        "白月光", "黑莲花", "女配", "反派", "下山", "退婚", "签到", "系统",
        "漫剧", "动态漫", "有声漫", "沙雕动画", "网大", "网络大电影", "网剧",
        "一口气看完", "全集解说", "逆袭", "千金", "少爷", "大小姐", "小娇妻",
        "真千金", "假千金", "闪婚后", "带球跑", "追妻", "火葬场", "团宠", "萌娃"
    ]

    static let cheapWebDramaStudios: [String] = [
        "横店", "快手", "抖音", "红果", "番茄", "九州", "点众", "容量", "麦芽", "微短剧"
    ]

    static let domesticIdolGenres: [String] = [
        "古偶", "仙侠", "甜宠", "都市", "爱情", "romance", "soap", "肥皂剧", "言情", "偶像"
    ]

    static let prestigeGenres: [String] = [
        "剧情", "drama", "科幻", "sci-fi", "science fiction", "悬疑", "mystery",
        "惊悚", "thriller", "犯罪", "crime", "战争", "war", "历史", "history",
        "传记", "biography", "纪录", "documentary", "冒险", "adventure", "奇幻", "fantasy"
    ]

    static let varietyGenresAndKeywords: [String] = [
        "综艺", "真人秀", "脱口秀", "晚会", "演唱会", "reality", "talk", "talk show", "news", "game show"
    ]

    /// 22 minutes in Emby ticks (1 tick = 100ns).
    static let shortEpisodeTicksThreshold: Int64 = 22 * 60 * 10_000_000

    // MARK: - Public Anime & Server Context Helpers

    /// Returns true if a library/collection name represents an anime/animation category.
    public static func isAnimeLibraryName(_ name: String?) -> Bool {
        guard let lower = name?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(), !lower.isEmpty else {
            return false
        }
        return animeLibraryKeywords.contains { lower.contains($0) }
    }

    /// Returns true when a media item is anime or animation based on library, genres, studios, or title markers.
    public static func isAnimeOrAnimation(_ item: EmbyItem, libraryName: String? = nil) -> Bool {
        if isAnimeLibraryName(libraryName) { return true }
        if let genres = item.genres {
            for g in genres {
                let gl = g.lowercased()
                if animeGenreKeywords.contains(where: { gl.contains($0) }) { return true }
            }
        }
        if let studios = item.studios {
            for s in studios {
                let sl = (s.name ?? "").lowercased()
                if !sl.isEmpty && animeStudioKeywords.contains(where: { sl.contains($0) }) { return true }
            }
        }
        let nameLower = item.name.lowercased()
        let taglineLower = (item.taglines ?? []).joined(separator: " ").lowercased()
        if animeTitleKeywords.contains(where: { nameLower.contains($0) || taglineLower.contains($0) }) {
            return true
        }
        return false
    }

    /// Determines whether anime content is allowed on the homepage (hero & pushed shelves).
    /// - `explicitAnimeMode`: non-nil for multi-hall servers (e.g. UHD Normal Hall = `false`, Anime Hall = `true`).
    /// - For standard servers (`nil`), returns `true` only when the server name or >= 50% of libraries are anime-focused.
    public static func isAnimeFocusedServer(
        serverName: String? = nil,
        libraryViews: [EmbyItem] = [],
        explicitAnimeMode: Bool? = nil
    ) -> Bool {
        if let explicitAnimeMode { return explicitAnimeMode }
        if let nameLower = serverName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !nameLower.isEmpty,
           animeServerKeywords.contains(where: { nameLower.contains($0) }) {
            return true
        }
        guard !libraryViews.isEmpty else { return false }
        let animeCount = libraryViews.filter { isAnimeLibraryName($0.name) }.count
        return animeCount > 0 && animeCount * 2 >= libraryViews.count
    }

    // MARK: - Internal Signal & Script Helpers

    static func normalizedDedupeKey(for item: EmbyItem) -> String {
        let cleanName = item.name
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let year = resolvedYear(for: item) ?? 0
        let kind = item.isSeries ? "s" : (item.type?.lowercased() ?? "m")
        return "\(kind)|\(cleanName)|\(year)"
    }

    static func resolvedYear(for item: EmbyItem) -> Int? {
        if let y = item.productionYear, y >= 1900 && y <= 2100 {
            return y
        }
        if let premiere = item.premiereDate, premiere.count >= 4,
           let y = Int(premiere.prefix(4)), y >= 1900 && y <= 2100 {
            return y
        }
        return nil
    }

    static func detectOrigin(item: EmbyItem, libraryLower: String) -> OriginClass {
        let libIsForeign = foreignLibraryKeywords.contains { libraryLower.contains($0) }
        let libIsDomestic = domesticLibraryKeywords.contains { libraryLower.contains($0) }

        if let orig = item.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !orig.isEmpty {
            let origHasForeign = containsForeignScript(orig)
            let origHasCJK = containsCJK(orig)
            if origHasForeign && !origHasCJK {
                return .foreign
            }
            if origHasForeign && origHasCJK {
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
            return .domestic
        }
        return .unknown
    }

    static func countCheapWebDramaSignals(
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

    static func hasWideBackdrop(_ item: EmbyItem) -> Bool {
        if let uhdBackdrop = item.uhdBackdropURL, !uhdBackdrop.isEmpty { return true }
        if let tags = item.backdropImageTags, !tags.isEmpty { return true }
        if let parentTags = item.parentBackdropImageTags, !parentTags.isEmpty { return true }
        if let thumb = item.uhdThumbURL, !thumb.isEmpty { return true }
        if let thumbTag = item.imageTags?["Thumb"], !thumbTag.isEmpty { return true }
        return false
    }

    static func hasPosterOrThumb(_ item: EmbyItem) -> Bool {
        if let uhdPoster = item.uhdPosterURL, !uhdPoster.isEmpty { return true }
        if let primary = item.imageTags?["Primary"], !primary.isEmpty { return true }
        return false
    }

    static func hasClearLogo(_ item: EmbyItem) -> Bool {
        if let uhdLogo = item.uhdLogoURL, !uhdLogo.isEmpty { return true }
        if let logo = item.imageTags?["Logo"], !logo.isEmpty { return true }
        return false
    }

    static func containsCJK(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                return true
            }
        }
        return false
    }

    static func cjkCharacterCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) {
                count += 1
            }
        }
        return count
    }

    static func containsKanaOrHangul(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x3040...0x30FF).contains(v) || (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) {
                return true
            }
        }
        return false
    }

    static func containsForeignScript(_ text: String) -> Bool {
        if containsKanaOrHangul(text) { return true }
        var latinLetters = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
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

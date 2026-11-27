import Foundation

extension HomeHeroCurator {
    enum OriginClass {
        case western
        case japanese
        case korean
        case thaiOrSEA
        case domestic
        case unknown
    }

    // MARK: - Keyword Tables

    static let westernLibraryKeywords: [String] = [
        "欧美", "美剧", "英剧", "欧洲", "好莱坞", "hollywood", "western", "us/uk", "uk/us", "hbo", "bbc"
    ]

    static let japaneseLibraryKeywords: [String] = [
        "日剧", "日本", "japanese", "jdrama"
    ]

    static let koreanLibraryKeywords: [String] = [
        "韩剧", "韩国", "日韩", "korean", "kdrama"
    ]

    static let thaiLibraryKeywords: [String] = [
        "泰剧", "泰国", "东南亚", "thai", "lakorn", "腐剧", "泰腐"
    ]

    static let domesticLibraryKeywords: [String] = [
        "国产", "华语", "大陆", "内地", "国剧", "短剧", "微短剧", "网剧",
        "国产剧", "内地剧", "中文剧", "港台"
    ]

    static let koreanStudioKeywords: [String] = [
        "tvn", "jtbc", "studio dragon", "sbs", "mbc", "kbs", "ocn", "ena", "wavve", "tving", "coupang play"
    ]

    static let thaiStudioKeywords: [String] = [
        "gmmtv", "gmm25", "be on cloud", "one31", "channel 3", "ch3", "ch7", "nadao",
        "domundi", "me mind y", "wabi sabi", "star hunter", "change2561", "idol factory", "copy a bangkok", "gdh"
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

    /// Universal idol / romance / soap / melodrama genres scrutinized heavily on Korean, Thai, and Domestic series.
    static let domesticIdolGenres: [String] = [
        "古偶", "仙侠", "甜宠", "都市", "爱情", "romance", "soap", "肥皂剧", "言情", "偶像", "melodrama", "浪漫", "狗血"
    ]

    /// Explicit BL / Y-series / idol fandom signals (heavily filtered on hero unless backed by extraordinary critical acclaim).
    static let blAndIdolFandomKeywords: [String] = [
        "boys' love", "boys love", "y-series", "lakorn", "泰腐", "腐剧", "耽美", "耽改",
        "同性恋情", "校园恋爱", "先婚后爱", "契约恋爱", "财阀恋", "霸道总裁", "甜宠剧", "偶像剧", "恋综", "双男主", "gl剧", "bl剧"
    ]

    static let prestigeGenres: [String] = [
        "剧情", "drama", "科幻", "sci-fi", "science fiction", "悬疑", "mystery",
        "惊悚", "thriller", "犯罪", "crime", "战争", "war", "历史", "history",
        "传记", "biography", "冒险", "adventure", "奇幻", "fantasy"
    ]

    static let documentaryKeywords: [String] = [
        "纪录片", "纪录", "记录片", "纪实", "documentary", "docuseries", "docu-series"
    ]

    static let documentaryStudioKeywords: [String] = [
        "bbc earth", "national geographic", "discovery channel", "history channel", "nhk documentary", "animal planet"
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

    /// Returns true when a media item is a documentary or docuseries (by library, genres, or documentary studios).
    public static func isDocumentary(_ item: EmbyItem, libraryName: String? = nil) -> Bool {
        if let libLower = libraryName?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
           !libLower.isEmpty,
           documentaryKeywords.contains(where: { libLower.contains($0) }) {
            return true
        }
        if let genres = item.genres {
            for g in genres {
                let gl = g.lowercased()
                if documentaryKeywords.contains(where: { gl.contains($0) }) { return true }
            }
        }
        if let studios = item.studios {
            for s in studios {
                let sl = (s.name ?? "").lowercased()
                if !sl.isEmpty && documentaryStudioKeywords.contains(where: { sl.contains($0) }) { return true }
            }
        }
        return false
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

    static func detectOrigin(
        item: EmbyItem,
        libraryLower: String,
        externalCountries: [String]? = nil
    ) -> OriginClass {
        // 1. Explicit production country metadata (e.g. Cinemeta / MDBList) is the most authoritative signal.
        if let countries = externalCountries, !countries.isEmpty {
            let joined = countries.map { $0.lowercased() }.joined(separator: " | ")
            if joined.contains("thailand") || joined.contains("philippines") || joined.contains("vietnam") || joined.contains("indonesia") {
                return .thaiOrSEA
            }
            if joined.contains("south korea") || joined.contains("korea") {
                return .korean
            }
            if joined.contains("japan") {
                return .japanese
            }
            if joined.contains("united states") || joined.contains("united kingdom") || joined.contains("canada")
                || joined.contains("france") || joined.contains("germany") || joined.contains("spain")
                || joined.contains("italy") || joined.contains("australia") || joined.contains("sweden")
                || joined.contains("denmark") || joined.contains("norway") || joined.contains("ireland")
                || joined.contains("new zealand") || joined.contains("poland") {
                return .western
            }
            if joined.contains("china") || joined.contains("hong kong") || joined.contains("taiwan") {
                return .domestic
            }
        }

        // 2. Network / studio markers (distinguish Thai BL & K-drama studios even under generic "剧集" libraries).
        let studioLower = (item.studios ?? []).compactMap { $0.name?.lowercased() }.joined(separator: " ")
        if !studioLower.isEmpty {
            if thaiStudioKeywords.contains(where: { studioLower.contains($0) }) { return .thaiOrSEA }
            if koreanStudioKeywords.contains(where: { studioLower.contains($0) }) { return .korean }
        }

        // 3. Original title Unicode script detection (precise regional split).
        if let orig = item.originalTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !orig.isEmpty {
            if containsThaiScript(orig) { return .thaiOrSEA }
            if containsHangul(orig) { return .korean }
            if containsKana(orig) { return .japanese }
            let origHasWestern = containsWesternForeignScript(orig)
            let origHasCJK = containsCJK(orig)
            if origHasWestern && !origHasCJK {
                return .western
            }
            if origHasCJK && !origHasWestern {
                if japaneseLibraryKeywords.contains(where: { libraryLower.contains($0) }) { return .japanese }
                if koreanLibraryKeywords.contains(where: { libraryLower.contains($0) }) { return .korean }
                if thaiLibraryKeywords.contains(where: { libraryLower.contains($0) }) { return .thaiOrSEA }
                return .domestic
            }
        }

        // 4. Library name classification.
        if thaiLibraryKeywords.contains(where: { libraryLower.contains($0) }) { return .thaiOrSEA }
        if koreanLibraryKeywords.contains(where: { libraryLower.contains($0) }) { return .korean }
        if japaneseLibraryKeywords.contains(where: { libraryLower.contains($0) }) { return .japanese }
        if westernLibraryKeywords.contains(where: { libraryLower.contains($0) }) { return .western }
        if domesticLibraryKeywords.contains(where: { libraryLower.contains($0) }) { return .domestic }

        // 5. Display name fallback.
        let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if containsThaiScript(name) { return .thaiOrSEA }
        if containsHangul(name) { return .korean }
        if containsKana(name) { return .japanese }
        if containsWesternForeignScript(name) && !containsCJK(name) { return .western }
        if containsCJK(name) && item.isSeries { return .domestic }
        return .unknown
    }

    private struct FastUTF8KeywordMatcher {
        private struct Entry {
            let index: Int
            let bytes: [UInt8]
            let hasASCII: Bool
        }

        private let buckets: [UInt32: [Entry]]

        init(_ keywords: [String]) {
            var map: [UInt32: [Entry]] = [:]
            for (idx, kw) in keywords.enumerated() {
                let bytes = Array(kw.lowercased().utf8)
                guard let first = bytes.first else { continue }
                let key = Self.bucketKey(bytes: bytes, index: 0, count: bytes.count, b0: first)
                let hasASCII = bytes.contains { $0 < 0x80 }
                map[key, default: []].append(Entry(index: idx, bytes: bytes, hasASCII: hasASCII))
            }
            self.buckets = map
        }

        @inline(__always)
        private static func bucketKey(bytes: [UInt8], index i: Int, count: Int, b0: UInt8) -> UInt32 {
            if b0 < 0x80 {
                let lower = (b0 >= 65 && b0 <= 90) ? (b0 &+ 32) : b0
                return UInt32(lower)
            } else if b0 >= 0xE0 && b0 < 0xF0 && i + 2 < count {
                return (UInt32(b0) << 16) | (UInt32(bytes[i + 1]) << 8) | UInt32(bytes[i + 2])
            } else if b0 >= 0xC0 && b0 < 0xE0 && i + 1 < count {
                return (UInt32(b0) << 8) | UInt32(bytes[i + 1])
            }
            return UInt32(b0)
        }

        @inline(__always)
        private static func bufferKey(_ base: UnsafePointer<UInt8>, index i: Int, count: Int, b0: UInt8) -> (key: UInt32, step: Int) {
            if b0 < 0x80 {
                let lower = (b0 >= 65 && b0 <= 90) ? (b0 &+ 32) : b0
                return (UInt32(lower), 1)
            } else if b0 >= 0xE0 && b0 < 0xF0 && i + 2 < count {
                return ((UInt32(b0) << 16) | (UInt32(base[i + 1]) << 8) | UInt32(base[i + 2]), 3)
            } else if b0 >= 0xC0 && b0 < 0xE0 && i + 1 < count {
                return ((UInt32(b0) << 8) | UInt32(base[i + 1]), 2)
            } else if b0 >= 0xF0 && i + 3 < count {
                return (UInt32(b0), 4)
            }
            return (UInt32(b0), 1)
        }

        @inline(__always)
        private static func matches(_ ptr: UnsafePointer<UInt8>, _ entry: Entry) -> Bool {
            let len = entry.bytes.count
            if !entry.hasASCII {
                for j in 0..<len where ptr[j] != entry.bytes[j] {
                    return false
                }
                return true
            }
            for j in 0..<len {
                let b = ptr[j]
                let lb = (b >= 65 && b <= 90) ? (b &+ 32) : b
                if lb != entry.bytes[j] { return false }
            }
            return true
        }

        func countUniqueMatches<C: Collection>(
            in utf8: C,
            matchedMask: inout UInt64,
            overflowMatched: inout Set<Int>?,
            hits: inout Int
        ) where C.Element == UInt8 {
            let handled: Void? = utf8.withContiguousStorageIfAvailable { buf in
                scanCountBuffer(buf, matchedMask: &matchedMask, overflowMatched: &overflowMatched, hits: &hits)
            }
            if handled == nil {
                let contiguous = Array(utf8)
                contiguous.withUnsafeBufferPointer { buf in
                    scanCountBuffer(buf, matchedMask: &matchedMask, overflowMatched: &overflowMatched, hits: &hits)
                }
            }
        }

        func containsAny<C: Collection>(in utf8: C) -> Bool where C.Element == UInt8 {
            if let hit = utf8.withContiguousStorageIfAvailable({ scanAnyBuffer($0) }) {
                return hit
            }
            let contiguous = Array(utf8)
            return contiguous.withUnsafeBufferPointer { scanAnyBuffer($0) }
        }

        private func scanCountBuffer(
            _ buf: UnsafeBufferPointer<UInt8>,
            matchedMask: inout UInt64,
            overflowMatched: inout Set<Int>?,
            hits: inout Int
        ) {
            let count = buf.count
            guard count > 0, let base = buf.baseAddress else { return }
            var i = 0
            while i < count {
                let b0 = base[i]
                let (key, step) = Self.bufferKey(base, index: i, count: count, b0: b0)
                if let candidates = buckets[key] {
                    for entry in candidates {
                        let bitIdx = entry.index
                        if bitIdx < 64 {
                            if (matchedMask & (1 << bitIdx)) != 0 { continue }
                        } else if overflowMatched?.contains(bitIdx) == true {
                            continue
                        }
                        let kwLen = entry.bytes.count
                        if i + kwLen <= count && Self.matches(base + i, entry) {
                            if bitIdx < 64 {
                                matchedMask |= (1 << bitIdx)
                            } else {
                                if overflowMatched == nil { overflowMatched = [] }
                                overflowMatched?.insert(bitIdx)
                            }
                            hits += 1
                        }
                    }
                }
                i += step
            }
        }

        private func scanAnyBuffer(_ buf: UnsafeBufferPointer<UInt8>) -> Bool {
            let count = buf.count
            guard count > 0, let base = buf.baseAddress else { return false }
            var i = 0
            while i < count {
                let b0 = base[i]
                let (key, step) = Self.bufferKey(base, index: i, count: count, b0: b0)
                if let candidates = buckets[key] {
                    for entry in candidates {
                        let kwLen = entry.bytes.count
                        if i + kwLen <= count && Self.matches(base + i, entry) {
                            return true
                        }
                    }
                }
                i += step
            }
            return false
        }
    }

    private static let cheapWebDramaMatcher = FastUTF8KeywordMatcher(cheapWebDramaKeywords)
    private static let cheapWebDramaStudioMatcher = FastUTF8KeywordMatcher(cheapWebDramaStudios)
    private static let domesticIdolGenreMatcher = FastUTF8KeywordMatcher(domesticIdolGenres)
    private static let blAndIdolFandomMatcher = FastUTF8KeywordMatcher(blAndIdolFandomKeywords)
    private static let thaiStudioMatcher = FastUTF8KeywordMatcher(thaiStudioKeywords)

    static func hasIdolBLOrRomanceSignals(
        item: EmbyItem,
        libraryLower: String,
        genresLower: [String]
    ) -> (hasIdolRomanceGenre: Bool, hasExplicitBLOrFandom: Bool) {
        let hasIdolRomanceGenre = genresLower.contains { domesticIdolGenreMatcher.containsAny(in: $0.utf8) }

        var hasExplicitBL = blAndIdolFandomMatcher.containsAny(in: item.name.utf8)
            || blAndIdolFandomMatcher.containsAny(in: libraryLower.utf8)
            || genresLower.contains { blAndIdolFandomMatcher.containsAny(in: $0.utf8) }
        if !hasExplicitBL, let taglines = item.taglines {
            for t in taglines where blAndIdolFandomMatcher.containsAny(in: t.utf8) {
                hasExplicitBL = true
                break
            }
        }
        if !hasExplicitBL, let overview = item.overview, !overview.isEmpty {
            hasExplicitBL = blAndIdolFandomMatcher.containsAny(in: overview.prefix(220).utf8)
        }
        if !hasExplicitBL, let studios = item.studios {
            for s in studios {
                if let sName = s.name, !sName.isEmpty, thaiStudioMatcher.containsAny(in: sName.utf8) {
                    hasExplicitBL = true
                    break
                }
            }
        }

        return (hasIdolRomanceGenre, hasExplicitBL)
    }

    static func countCheapWebDramaSignals(
        item: EmbyItem,
        libraryLower: String,
        genresLower: [String]
    ) -> Int {
        var hits = 0
        var matchedMask: UInt64 = 0
        var overflowMatched: Set<Int>? = nil

        cheapWebDramaMatcher.countUniqueMatches(in: item.name.utf8, matchedMask: &matchedMask, overflowMatched: &overflowMatched, hits: &hits)
        if !libraryLower.isEmpty {
            cheapWebDramaMatcher.countUniqueMatches(in: libraryLower.utf8, matchedMask: &matchedMask, overflowMatched: &overflowMatched, hits: &hits)
        }
        for genre in genresLower where !genre.isEmpty {
            cheapWebDramaMatcher.countUniqueMatches(in: genre.utf8, matchedMask: &matchedMask, overflowMatched: &overflowMatched, hits: &hits)
        }
        if let taglines = item.taglines {
            for tagline in taglines where !tagline.isEmpty {
                cheapWebDramaMatcher.countUniqueMatches(in: tagline.utf8, matchedMask: &matchedMask, overflowMatched: &overflowMatched, hits: &hits)
            }
        }
        if let overview = item.overview, !overview.isEmpty {
            cheapWebDramaMatcher.countUniqueMatches(in: overview.prefix(160).utf8, matchedMask: &matchedMask, overflowMatched: &overflowMatched, hits: &hits)
        }

        if let studios = item.studios, !studios.isEmpty {
            var studioMask: UInt64 = 0
            var studioOverflow: Set<Int>? = nil
            for studio in studios {
                if let name = studio.name, !name.isEmpty {
                    cheapWebDramaStudioMatcher.countUniqueMatches(in: name.utf8, matchedMask: &studioMask, overflowMatched: &studioOverflow, hits: &hits)
                }
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
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) { return true }
        }
        return false
    }

    static func cjkCharacterCount(_ text: String) -> Int {
        var count = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v) { count += 1 }
        }
        return count
    }

    static func containsKana(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if (0x3040...0x30FF).contains(scalar.value) { return true }
        }
        return false
    }

    static func containsHangul(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            let v = scalar.value
            if (0xAC00...0xD7AF).contains(v) || (0x1100...0x11FF).contains(v) { return true }
        }
        return false
    }

    static func containsThaiScript(_ text: String) -> Bool {
        for scalar in text.unicodeScalars {
            if (0x0E00...0x0E7F).contains(scalar.value) { return true }
        }
        return false
    }

    static func containsWesternForeignScript(_ text: String) -> Bool {
        var latinLetters = 0
        for scalar in text.unicodeScalars {
            let v = scalar.value
            // Cyrillic, Greek, Arabic, Devanagari, Latin Extended (excluding Thai/Hangul/Kana)
            if (0x0400...0x04FF).contains(v)
                || (0x0370...0x03FF).contains(v)
                || (0x0600...0x06FF).contains(v)
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

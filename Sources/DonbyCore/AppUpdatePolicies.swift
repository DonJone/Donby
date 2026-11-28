import Foundation

public enum DonbyAppInfo {
    public static let fallbackVersion = "2.1.8"
    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackVersion
    }

    public static var compiledArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    public static var isRunningUnderRosetta: Bool {
        var translated: Int32 = 0
        var size = MemoryLayout<Int32>.size
        if sysctlbyname("sysctl.proc_translated", &translated, &size, nil, 0) == 0 {
            return translated == 1
        }
        return false
    }

    public static var preferredUpdateArchitecture: String {
        #if arch(arm64)
        return "arm64"
        #else
        return isRunningUnderRosetta ? "arm64" : "x86_64"
        #endif
    }

    public static var architectureDisplayName: String {
        #if arch(arm64)
        return "Apple Silicon"
        #else
        return isRunningUnderRosetta ? "Intel x64 (Rosetta 2)" : "Intel x64"
        #endif
    }

    public static func machOBinarySupportsArchitecture(at url: URL, requiredArch: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096) else { return false }
        return machOHeaderSupportsArchitecture(headerBytes: header, requiredArch: requiredArch)
    }

    public static func machOHeaderSupportsArchitecture(headerBytes data: Data, requiredArch: String) -> Bool {
        let targetArch = requiredArch.lowercased()
        let requiredCPUType: UInt32
        switch targetArch {
        case "arm64", "aarch64":
            requiredCPUType = 0x0100_000c // CPU_TYPE_ARM64
        case "x86_64", "x64":
            requiredCPUType = 0x0100_0007 // CPU_TYPE_X86_64
        default:
            return false
        }

        guard data.count >= 8 else { return false }
        func readU32LE(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return UInt32(data[offset])
                | (UInt32(data[offset + 1]) << 8)
                | (UInt32(data[offset + 2]) << 16)
                | (UInt32(data[offset + 3]) << 24)
        }
        func readU32BE(_ offset: Int) -> UInt32? {
            guard offset + 4 <= data.count else { return nil }
            return (UInt32(data[offset]) << 24)
                | (UInt32(data[offset + 1]) << 16)
                | (UInt32(data[offset + 2]) << 8)
                | UInt32(data[offset + 3])
        }

        let magicLE = readU32LE(0) ?? 0
        let magicBE = readU32BE(0) ?? 0
        if magicLE == 0xfeed_facf { // MH_MAGIC_64
            return readU32LE(4) == requiredCPUType
        }
        if magicBE == 0xcafe_babe { // FAT_MAGIC (big-endian)
            let count = Int(readU32BE(4) ?? 0)
            guard count > 0, count <= 16 else { return false }
            for idx in 0..<count {
                let offset = 8 + idx * 20
                if readU32BE(offset) == requiredCPUType {
                    return true
                }
            }
            return false
        }
        if magicBE == 0xcafe_babf { // FAT_MAGIC_64 (big-endian)
            let count = Int(readU32BE(4) ?? 0)
            guard count > 0, count <= 16 else { return false }
            for idx in 0..<count {
                let offset = 8 + idx * 32
                if readU32BE(offset) == requiredCPUType {
                    return true
                }
            }
            return false
        }
        return false
    }
}

public enum AppUpdateChannel: String, CaseIterable, Codable, Identifiable, Sendable {
    case stable = "stable"
    case prerelease = "prerelease"

    public var id: String { rawValue }

    public var displayTitle: String {
        switch self {
        case .stable: return "正式版 (Stable)"
        case .prerelease: return "预览版 (Pre-release)"
        }
    }

    public var summaryDescription: String {
        switch self {
        case .stable: return "仅接收稳定正式版更新"
        case .prerelease: return "接收抢先体验与最新修复版本（含正式版）"
        }
    }
}

public struct AppReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let browserDownloadURL: URL
    public let size: Int64
    public let expectedSHA256: String?

    public init(name: String, browserDownloadURL: URL, size: Int64, expectedSHA256: String? = nil) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
        self.expectedSHA256 = expectedSHA256
    }
}

public struct AppReleaseInfo: Codable, Equatable, Identifiable, Sendable {
    public var id: String { tagName }
    public let tagName: String
    public let version: String
    public let name: String
    public let body: String
    public let htmlURL: URL
    public let publishedAt: Date?
    public let isPrerelease: Bool
    public let zipAsset: AppReleaseAsset?
    public let dmgAsset: AppReleaseAsset?
    public let checksumAsset: AppReleaseAsset?

    public var preferredUpdateAsset: AppReleaseAsset? {
        zipAsset ?? dmgAsset
    }

    public init(
        tagName: String,
        version: String,
        name: String,
        body: String,
        htmlURL: URL,
        publishedAt: Date?,
        isPrerelease: Bool = false,
        zipAsset: AppReleaseAsset? = nil,
        dmgAsset: AppReleaseAsset?,
        checksumAsset: AppReleaseAsset?
    ) {
        self.tagName = tagName
        self.version = version
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
        self.isPrerelease = isPrerelease
        self.zipAsset = zipAsset
        self.dmgAsset = dmgAsset
        self.checksumAsset = checksumAsset
    }
}

public enum AppUpdateParseError: LocalizedError, Sendable {
    case invalidPayload
    case missingDownloadAsset

    public var errorDescription: String? {
        switch self {
        case .invalidPayload:
            return "无法解析 GitHub Release 元数据"
        case .missingDownloadAsset:
            return "该版本未附带 macOS DMG 安装包"
        }
    }
}

public enum AppVersionComparator {
    private struct GitHubReleaseDTO: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
        let published_at: String?
        let draft: Bool?
        let prerelease: Bool?
        let assets: [GitHubAssetDTO]?
    }

    private struct GitHubAssetDTO: Decodable {
        let name: String
        let browser_download_url: String
        let size: Int64?
    }

    public static func normalizeVersion(_ raw: String) -> String {
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("v") || trimmed.hasPrefix("V") {
            trimmed.removeFirst()
        }
        if let plusIdx = trimmed.firstIndex(of: "+") {
            trimmed = String(trimmed[..<plusIdx])
        }
        if let dashIdx = trimmed.firstIndex(of: "-") {
            trimmed = String(trimmed[..<dashIdx])
        }
        return trimmed
    }

    public static func numericComponents(of raw: String) -> [Int] {
        let norm = normalizeVersion(raw)
        guard !norm.isEmpty else { return [0] }
        let parts = norm.split(separator: ".").map { segment -> Int in
            let digits = segment.prefix(while: { $0.isNumber })
            return Int(digits) ?? 0
        }
        return parts.isEmpty ? [0] : parts
    }

    public static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        let a = numericComponents(of: candidate)
        let b = numericComponents(of: current)
        let count = max(a.count, b.count)
        for i in 0..<count {
            let va = i < a.count ? a[i] : 0
            let vb = i < b.count ? b[i] : 0
            if va != vb {
                return va > vb
            }
        }
        return false
    }

    public static func parseGitHubLatestRelease(
        data: Data,
        preferredArch: String = DonbyAppInfo.preferredUpdateArchitecture
    ) throws -> AppReleaseInfo {
        let decoder = JSONDecoder()
        guard let dto = try? decoder.decode(GitHubReleaseDTO.self, from: data),
              let info = buildReleaseInfo(from: dto, preferredArch: preferredArch) else {
            throw AppUpdateParseError.invalidPayload
        }
        return info
    }

    public static func parseGitHubReleasesList(
        data: Data,
        preferredArch: String = DonbyAppInfo.preferredUpdateArchitecture,
        includePrereleases: Bool
    ) throws -> AppReleaseInfo? {
        let decoder = JSONDecoder()
        guard let list = try? decoder.decode([GitHubReleaseDTO].self, from: data) else {
            throw AppUpdateParseError.invalidPayload
        }
        let filtered = list.filter { dto in
            if dto.draft == true { return false }
            if !includePrereleases && dto.prerelease == true { return false }
            return true
        }
        var best: AppReleaseInfo? = nil
        for dto in filtered {
            guard let info = buildReleaseInfo(from: dto, preferredArch: preferredArch) else { continue }
            let hasIncompatibleOnlyAssets = !(dto.assets ?? []).isEmpty && info.preferredUpdateAsset == nil
            if hasIncompatibleOnlyAssets { continue }
            if let currentBest = best {
                if isVersion(info.version, newerThan: currentBest.version) {
                    best = info
                }
            } else {
                best = info
            }
        }
        return best
    }

    public static func classifyAssetArchitecture(_ fileName: String) -> String? {
        let lower = fileName.lowercased()
        if lower.contains("universal2") || lower.contains("universal") {
            return "universal"
        }
        if lower.contains("arm64") || lower.contains("aarch64") || lower.contains("apple-silicon") {
            return "arm64"
        }
        if lower.contains("x86_64") || lower.contains("x64") || lower.contains("amd64") || lower.contains("intel") {
            return "x86_64"
        }
        return nil
    }

    private static func selectCompatibleAsset(from candidates: [AppReleaseAsset], preferredArch: String) -> AppReleaseAsset? {
        let archLower = preferredArch.lowercased()
        if let exact = candidates.first(where: { classifyAssetArchitecture($0.name) == archLower }) {
            return exact
        }
        if let universal = candidates.first(where: { classifyAssetArchitecture($0.name) == "universal" }) {
            return universal
        }
        // Historical untyped Donby releases before dual-arch CI were arm64-only.
        if archLower == "arm64" {
            return candidates.first(where: { classifyAssetArchitecture($0.name) == nil })
        }
        return nil
    }

    private static func buildReleaseInfo(from dto: GitHubReleaseDTO, preferredArch: String) -> AppReleaseInfo? {
        guard let htmlURL = URL(string: dto.html_url) else { return nil }
        let assets = (dto.assets ?? []).compactMap { asset -> AppReleaseAsset? in
            guard let url = URL(string: asset.browser_download_url) else { return nil }
            return AppReleaseAsset(name: asset.name, browserDownloadURL: url, size: max(0, asset.size ?? 0))
        }

        let zipCandidates = assets.filter {
            let lower = $0.name.lowercased()
            return lower.hasSuffix(".app.zip") || lower.hasSuffix(".zip")
        }
        let appZipCandidates = zipCandidates.filter { $0.name.lowercased().hasSuffix(".app.zip") }
        let selectedZip = selectCompatibleAsset(from: appZipCandidates, preferredArch: preferredArch)
            ?? selectCompatibleAsset(from: zipCandidates, preferredArch: preferredArch)

        let dmgCandidates = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let selectedDmg = selectCompatibleAsset(from: dmgCandidates, preferredArch: preferredArch)

        let checksumAsset = assets.first {
            let lower = $0.name.lowercased()
            return lower == "sha256sums.txt" || lower.contains("sha256")
        }

        var parsedDate: Date? = nil
        if let pub = dto.published_at {
            parsedDate = parseISO8601Date(pub)
        }

        let normalized = normalizeVersion(dto.tag_name)
        let cleanTitle = (dto.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? dto.name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "v\(normalized)"

        return AppReleaseInfo(
            tagName: dto.tag_name,
            version: normalized,
            name: cleanTitle,
            body: cleanReleaseNotes(dto.body ?? ""),
            htmlURL: htmlURL,
            publishedAt: parsedDate,
            isPrerelease: dto.prerelease == true,
            zipAsset: selectedZip,
            dmgAsset: selectedDmg,
            checksumAsset: checksumAsset
        )
    }

    public static func cleanReleaseNotes(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n")
        if let markerRange = text.range(of: "\n### 安装说明") {
            text = String(text[..<markerRange.lowerBound])
        } else if text.hasPrefix("### 安装说明") {
            text = ""
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct PlatformManifestEntryDTO: Decodable {
        let dmg_name: String?
        let dmg_sha256: String?
        let dmg_size: Int64?
        let zip_name: String?
        let zip_sha256: String?
        let zip_size: Int64?
    }

    private struct StaticManifestDTO: Decodable {
        let version: String
        let tag_name: String
        let published_at: String?
        let arch: String?
        let dmg_name: String?
        let dmg_sha256: String?
        let dmg_size: Int64?
        let zip_name: String?
        let zip_sha256: String?
        let zip_size: Int64?
        let platforms: [String: PlatformManifestEntryDTO]?
        let notes: String?
    }

    public static func parseStaticManifestJSON(
        data: Data,
        preferredArch: String = DonbyAppInfo.preferredUpdateArchitecture,
        releaseBaseURL: URL = URL(string: "https://github.com/DonJone/Donby/releases")!
    ) throws -> AppReleaseInfo {
        guard let dto = try? JSONDecoder().decode(StaticManifestDTO.self, from: data) else {
            throw AppUpdateParseError.invalidPayload
        }
        let norm = normalizeVersion(dto.version.isEmpty ? dto.tag_name : dto.version)
        let tag = dto.tag_name.isEmpty ? "v\(norm)" : dto.tag_name
        let downloadBase = releaseBaseURL.appendingPathComponent("download").appendingPathComponent(tag)
        let htmlURL = releaseBaseURL.appendingPathComponent("tag").appendingPathComponent(tag)

        let archLower = preferredArch.lowercased()
        let selectedPlatform: PlatformManifestEntryDTO? = dto.platforms?[archLower] ?? dto.platforms?["universal"]

        let rawZipName: String?
        let rawZipSha: String?
        let rawZipSize: Int64?
        let rawDmgName: String?
        let rawDmgSha: String?
        let rawDmgSize: Int64?

        if let p = selectedPlatform {
            rawZipName = p.zip_name
            rawZipSha = p.zip_sha256
            rawZipSize = p.zip_size
            rawDmgName = p.dmg_name
            rawDmgSha = p.dmg_sha256
            rawDmgSize = p.dmg_size
        } else {
            let topArch = dto.arch?.lowercased()
            let topCompatible: Bool = {
                if let topArch {
                    return topArch == archLower || topArch == "universal"
                }
                if let candidateName = dto.zip_name ?? dto.dmg_name,
                   let nameArch = classifyAssetArchitecture(candidateName) {
                    return nameArch == archLower || nameArch == "universal"
                }
                return archLower == "arm64"
            }()
            if topCompatible {
                rawZipName = dto.zip_name
                rawZipSha = dto.zip_sha256
                rawZipSize = dto.zip_size
                rawDmgName = dto.dmg_name
                rawDmgSha = dto.dmg_sha256
                rawDmgSize = dto.dmg_size
            } else {
                rawZipName = nil; rawZipSha = nil; rawZipSize = nil
                rawDmgName = nil; rawDmgSha = nil; rawDmgSize = nil
            }
        }

        let zipAsset: AppReleaseAsset? = rawZipName.flatMap { name in
            AppReleaseAsset(
                name: name,
                browserDownloadURL: downloadBase.appendingPathComponent(name),
                size: max(0, rawZipSize ?? 0),
                expectedSHA256: rawZipSha
            )
        }
        let dmgAsset: AppReleaseAsset? = rawDmgName.flatMap { name in
            AppReleaseAsset(
                name: name,
                browserDownloadURL: downloadBase.appendingPathComponent(name),
                size: max(0, rawDmgSize ?? 0),
                expectedSHA256: rawDmgSha
            )
        }
        return AppReleaseInfo(
            tagName: tag,
            version: norm,
            name: "v\(norm)",
            body: (dto.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            htmlURL: htmlURL,
            publishedAt: dto.published_at.flatMap { parseISO8601Date($0) },
            zipAsset: zipAsset,
            dmgAsset: dmgAsset,
            checksumAsset: nil
        )
    }

    private static func parseISO8601Date(_ raw: String) -> Date? {
        let isoFrac = ISO8601DateFormatter()
        isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = isoFrac.date(from: raw) { return d }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: raw)
    }

    public static func parseSHA256Checksum(from content: String, matchingFileName fileName: String) -> String? {
        let targetName = fileName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let lines = content.components(separatedBy: .newlines)
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let tokens = trimmed.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard tokens.count >= 2 else { continue }
            let hash = tokens[0].lowercased()
            guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }
            let assetNameToken = tokens.dropFirst().joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "* "))
            let baseName = URL(fileURLWithPath: assetNameToken).lastPathComponent.lowercased()
            if baseName == targetName {
                return hash
            }
        }
        return nil
    }
}

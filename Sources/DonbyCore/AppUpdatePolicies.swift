import Foundation

public enum DonbyAppInfo {
    public static let fallbackVersion = "1.4.22"
    public static var version: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String) ?? fallbackVersion
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

    public static func parseGitHubLatestRelease(data: Data, preferredArch: String = "arm64") throws -> AppReleaseInfo {
        let decoder = JSONDecoder()
        guard let dto = try? decoder.decode(GitHubReleaseDTO.self, from: data),
              let info = buildReleaseInfo(from: dto, preferredArch: preferredArch) else {
            throw AppUpdateParseError.invalidPayload
        }
        return info
    }

    public static func parseGitHubReleasesList(
        data: Data,
        preferredArch: String = "arm64",
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
        let archLower = preferredArch.lowercased()
        let selectedZip = zipCandidates.first(where: { $0.name.lowercased().contains(archLower) && $0.name.lowercased().hasSuffix(".app.zip") })
            ?? zipCandidates.first(where: { $0.name.lowercased().hasSuffix(".app.zip") })
            ?? zipCandidates.first

        let dmgCandidates = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let selectedDmg = dmgCandidates.first(where: { $0.name.lowercased().contains(archLower) })
            ?? dmgCandidates.first

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

    private struct StaticManifestDTO: Decodable {
        let version: String
        let tag_name: String
        let published_at: String?
        let dmg_name: String?
        let dmg_sha256: String?
        let dmg_size: Int64?
        let zip_name: String?
        let zip_sha256: String?
        let zip_size: Int64?
        let notes: String?
    }

    public static func parseStaticManifestJSON(
        data: Data,
        releaseBaseURL: URL = URL(string: "https://github.com/DonJone/Donby/releases")!
    ) throws -> AppReleaseInfo {
        guard let dto = try? JSONDecoder().decode(StaticManifestDTO.self, from: data) else {
            throw AppUpdateParseError.invalidPayload
        }
        let norm = normalizeVersion(dto.version.isEmpty ? dto.tag_name : dto.version)
        let tag = dto.tag_name.isEmpty ? "v\(norm)" : dto.tag_name
        let downloadBase = releaseBaseURL.appendingPathComponent("download").appendingPathComponent(tag)
        let htmlURL = releaseBaseURL.appendingPathComponent("tag").appendingPathComponent(tag)

        let zipAsset: AppReleaseAsset? = dto.zip_name.flatMap { name in
            AppReleaseAsset(
                name: name,
                browserDownloadURL: downloadBase.appendingPathComponent(name),
                size: max(0, dto.zip_size ?? 0),
                expectedSHA256: dto.zip_sha256
            )
        }
        let dmgAsset: AppReleaseAsset? = dto.dmg_name.flatMap { name in
            AppReleaseAsset(
                name: name,
                browserDownloadURL: downloadBase.appendingPathComponent(name),
                size: max(0, dto.dmg_size ?? 0),
                expectedSHA256: dto.dmg_sha256
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

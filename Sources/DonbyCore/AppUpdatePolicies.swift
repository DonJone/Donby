import Foundation

public struct AppReleaseAsset: Codable, Equatable, Sendable {
    public let name: String
    public let browserDownloadURL: URL
    public let size: Int64

    public init(name: String, browserDownloadURL: URL, size: Int64) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
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
    public let dmgAsset: AppReleaseAsset?
    public let checksumAsset: AppReleaseAsset?

    public init(
        tagName: String,
        version: String,
        name: String,
        body: String,
        htmlURL: URL,
        publishedAt: Date?,
        dmgAsset: AppReleaseAsset?,
        checksumAsset: AppReleaseAsset?
    ) {
        self.tagName = tagName
        self.version = version
        self.name = name
        self.body = body
        self.htmlURL = htmlURL
        self.publishedAt = publishedAt
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
              let htmlURL = URL(string: dto.html_url) else {
            throw AppUpdateParseError.invalidPayload
        }

        let assets = (dto.assets ?? []).compactMap { asset -> AppReleaseAsset? in
            guard let url = URL(string: asset.browser_download_url) else { return nil }
            return AppReleaseAsset(name: asset.name, browserDownloadURL: url, size: max(0, asset.size ?? 0))
        }

        let dmgCandidates = assets.filter { $0.name.lowercased().hasSuffix(".dmg") }
        let archLower = preferredArch.lowercased()
        let selectedDmg = dmgCandidates.first(where: { $0.name.lowercased().contains(archLower) })
            ?? dmgCandidates.first

        let checksumAsset = assets.first {
            let lower = $0.name.lowercased()
            return lower == "sha256sums.txt" || lower.contains("sha256")
        }

        var parsedDate: Date? = nil
        if let pub = dto.published_at {
            let isoFrac = ISO8601DateFormatter()
            isoFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = isoFrac.date(from: pub) {
                parsedDate = d
            } else {
                let iso = ISO8601DateFormatter()
                iso.formatOptions = [.withInternetDateTime]
                parsedDate = iso.date(from: pub)
            }
        }

        let normalized = normalizeVersion(dto.tag_name)
        let cleanTitle = (dto.name?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            ? dto.name!.trimmingCharacters(in: .whitespacesAndNewlines)
            : "v\(normalized)"

        return AppReleaseInfo(
            tagName: dto.tag_name,
            version: normalized,
            name: cleanTitle,
            body: (dto.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
            htmlURL: htmlURL,
            publishedAt: parsedDate,
            dmgAsset: selectedDmg,
            checksumAsset: checksumAsset
        )
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

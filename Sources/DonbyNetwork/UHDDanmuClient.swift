import Foundation
import DonbyCore

private struct DanmuMatchResponseDTO: Decodable {
    let matches: [DanmuMatchEntryDTO]?
}

private struct DanmuMatchEntryDTO: Decodable {
    let episodeId: Int?
    let animeId: Int?
    let animeTitle: String?
    let episodeTitle: String?
    let typeDescription: String?
}

private struct DanmuSearchAnimeResponseDTO: Decodable {
    let animes: [DanmuAnimeSummaryDTO]?
}

private struct DanmuAnimeSummaryDTO: Decodable {
    let animeId: Int?
    let animeTitle: String?
    let typeDescription: String?
}

private struct DanmuBangumiResponseDTO: Decodable {
    let bangumi: DanmuBangumiDetailDTO?
}

private struct DanmuBangumiDetailDTO: Decodable {
    let animeId: Int?
    let animeTitle: String?
    let episodes: [DanmuEpisodeDTO]?
}

private struct DanmuEpisodeDTO: Decodable {
    let episodeId: Int?
    let episodeTitle: String?
}

private struct DanmuCommentsResponseDTO: Decodable {
    let comments: [DanmuRawCommentDTO]?
}

private struct DanmuRawCommentDTO: Decodable {
    let cid: Int64?
    let p: String?
    let m: String?
}

/// Client for UHD's managed Danmu API (`/api/v1/danmu/{token}/api/v2/...`).
/// Uses the resolved playback domain host and path-scoped token authentication.
/// Danmu traffic does NOT count toward UHD traffic quota or video delivery concurrency.
public final class UHDDanmuClient: Sendable {
    public static let shared = UHDDanmuClient()
    private let session: URLSession

    private init() {
        self.session = TurboStreamingSessionHub.shared.sharedURLSession
    }

    private func danmuBaseURL(server: EmbyServerConfig) async throws -> String {
        guard !server.accessToken.isEmpty else { throw EmbyClientError.unauthorized }
        let origin = try await UHDStreamClient.shared.resolveActivePlaybackOrigin(server: server)
        var cleanOrigin = origin.absoluteString
        while cleanOrigin.hasSuffix("/") { cleanOrigin.removeLast() }
        let encodedToken = server.accessToken.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? server.accessToken
        return "\(cleanOrigin)/api/v1/danmu/\(encodedToken)"
    }

    private func performData(request: URLRequest) async throws -> Data {
        let (data, resp) = try await session.data(for: request)
        if let http = resp as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            if http.statusCode == 429 {
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After") ?? "6"
                throw EmbyClientError.httpStatus(429, "弹幕请求过于频繁，请 \(retryAfter) 秒后重试")
            }
            if http.statusCode == 401 { throw EmbyClientError.unauthorized }
            throw EmbyClientError.httpStatus(http.statusCode, "弹幕服务返回 HTTP \(http.statusCode)")
        }
        return data
    }

    public func match(server: EmbyServerConfig, fileName: String, fileSize: Int64 = 0, videoDurationSeconds: Int = 0) async throws -> [UHDDanmuAnimeMatch] {
        let base = try await danmuBaseURL(server: server)
        guard let url = URL(string: "\(base)/api/v2/match") else {
            throw EmbyClientError.invalidServerURL(PlaybackDiagnosticsRedactor.redact("\(base)/api/v2/match"))
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.httpMethod = "POST"
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        req.setValue("Donby/\(DonbyAppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        let payload: [String: Any] = [
            "fileName": fileName,
            "fileHash": "00000000000000000000000000000000",
            "fileSize": max(0, fileSize),
            "videoDuration": max(0, videoDurationSeconds),
            "matchMode": "fileNameOnly"
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let data = try await performData(request: req)
        let dto = try JSONDecoder().decode(DanmuMatchResponseDTO.self, from: data)
        return (dto.matches ?? []).compactMap { m in
            guard let aid = m.animeId, let title = m.animeTitle, !title.isEmpty else { return nil }
            return UHDDanmuAnimeMatch(
                animeId: aid,
                animeTitle: title,
                episodeId: m.episodeId,
                episodeTitle: m.episodeTitle,
                typeDescription: m.typeDescription
            )
        }
    }

    public func searchAnime(server: EmbyServerConfig, keyword: String) async throws -> [UHDDanmuAnimeMatch] {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let base = try await danmuBaseURL(server: server)
        guard var comps = URLComponents(string: "\(base)/api/v2/search/anime") else {
            throw EmbyClientError.invalidServerURL("danmu/search/anime")
        }
        comps.queryItems = [URLQueryItem(name: "keyword", value: trimmed)]
        guard let url = comps.url else { throw EmbyClientError.invalidServerURL("danmu/search/anime") }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Donby/\(DonbyAppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        let data = try await performData(request: req)
        let dto = try JSONDecoder().decode(DanmuSearchAnimeResponseDTO.self, from: data)
        return (dto.animes ?? []).compactMap { a in
            guard let aid = a.animeId, let title = a.animeTitle else { return nil }
            return UHDDanmuAnimeMatch(animeId: aid, animeTitle: title, typeDescription: a.typeDescription)
        }
    }

    public func fetchBangumiEpisodes(server: EmbyServerConfig, animeId: Int) async throws -> [UHDDanmuEpisodeOption] {
        let base = try await danmuBaseURL(server: server)
        guard let url = URL(string: "\(base)/api/v2/bangumi/\(animeId)") else {
            throw EmbyClientError.invalidServerURL("danmu/bangumi")
        }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Donby/\(DonbyAppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        let data = try await performData(request: req)
        let dto = try JSONDecoder().decode(DanmuBangumiResponseDTO.self, from: data)
        return (dto.bangumi?.episodes ?? []).compactMap { ep in
            guard let eid = ep.episodeId else { return nil }
            return UHDDanmuEpisodeOption(episodeId: eid, episodeTitle: ep.episodeTitle ?? "第 \(eid) 集")
        }
    }

    public func fetchComments(server: EmbyServerConfig, commentId: Int) async throws -> [UHDDanmuComment] {
        let base = try await danmuBaseURL(server: server)
        guard var comps = URLComponents(string: "\(base)/api/v2/comment/\(commentId)") else {
            throw EmbyClientError.invalidServerURL("danmu/comment")
        }
        comps.queryItems = [
            URLQueryItem(name: "withRelated", value: "true"),
            URLQueryItem(name: "chConvert", value: "1")
        ]
        guard let url = comps.url else { throw EmbyClientError.invalidServerURL("danmu/comment") }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Donby/\(DonbyAppInfo.version) (macOS)", forHTTPHeaderField: "User-Agent")
        let data = try await performData(request: req)
        let dto = try JSONDecoder().decode(DanmuCommentsResponseDTO.self, from: data)
        return Self.parseComments(dto.comments ?? [])
    }

    /// Convenience helper: auto-matches a movie or episode and loads its danmu comments.
    public func autoLoadComments(
        server: EmbyServerConfig,
        item: EmbyItem,
        mediaSource: MediaSourceInfo?
    ) async throws -> (matchedTitle: String, episodeId: Int, comments: [UHDDanmuComment])? {
        let queryName: String = {
            if item.isEpisode, let series = item.seriesName, !series.isEmpty {
                let epStr = item.episodeCodeString ?? (item.indexNumber.map { "E\($0)" } ?? "")
                return "\(series) \(epStr)".trimmingCharacters(in: .whitespaces)
            }
            if let srcName = mediaSource?.name, !srcName.isEmpty, srcName.count >= 4 {
                return "\(item.name) \(srcName)"
            }
            return item.name
        }()

        let matches = (try? await match(
            server: server,
            fileName: queryName,
            fileSize: mediaSource?.size ?? 0,
            videoDurationSeconds: Int(item.durationSeconds)
        )) ?? []

        if let best = matches.first, let epId = best.episodeId {
            let comments = try await fetchComments(server: server, commentId: epId)
            let label = [best.animeTitle, best.episodeTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
            return (label.isEmpty ? item.name : label, epId, comments)
        }

        // Fallback: search by title + pick matching episode index
        let keyword = (item.isEpisode ? (item.seriesName ?? item.name) : item.name)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else { return nil }
        let searchResults = try await searchAnime(server: server, keyword: keyword)
        guard let firstAnime = searchResults.first else { return nil }
        let episodes = try await fetchBangumiEpisodes(server: server, animeId: firstAnime.animeId)
        guard !episodes.isEmpty else { return nil }
        let chosen: UHDDanmuEpisodeOption = {
            if item.isEpisode, let epNum = item.indexNumber, epNum >= 1, epNum <= episodes.count {
                return episodes[epNum - 1]
            }
            return episodes[0]
        }()
        let comments = try await fetchComments(server: server, commentId: chosen.episodeId)
        return ("\(firstAnime.animeTitle) · \(chosen.episodeTitle)", chosen.episodeId, comments)
    }

    private static func parseComments(_ raw: [DanmuRawCommentDTO]) -> [UHDDanmuComment] {
        var result: [UHDDanmuComment] = []
        result.reserveCapacity(raw.count)
        for (idx, item) in raw.enumerated() {
            guard let text = item.m?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let p = item.p else { continue }
            let parts = p.split(separator: ",")
            guard let time = parts.first.flatMap({ Double($0) }), time >= 0 else { continue }
            let mode = parts.count > 1 ? (Int(parts[1]) ?? 1) : 1
            let color = parts.count > 2 ? (UInt32(parts[2]) ?? 0xFFFFFF) : 0xFFFFFF
            let cid = item.cid.map(String.init) ?? "\(idx)-\(Int(time * 100))"
            result.append(UHDDanmuComment(id: cid, timeSeconds: time, mode: mode, colorRGB: color, text: text))
        }
        result.sort { $0.timeSeconds < $1.timeSeconds }
        return result
    }
}

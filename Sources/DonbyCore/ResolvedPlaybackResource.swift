import Foundation

public struct SubtitleResourceItem: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(name)|\(url.absoluteString)" }
    public let name: String
    public let url: URL

    public init(name: String, url: URL) {
        self.name = name; self.url = url
    }
}

public struct ResolvedPlaybackResource: Sendable, Equatable {
    public let streamURL: URL
    public let headers: [String: String]
    public let playSessionId: String
    public let mediaSource: MediaSourceInfo
    public let subtitleURLs: [SubtitleResourceItem]
    public let isDirectStream: Bool
    public let routeNote: String

    public init(streamURL: URL, headers: [String: String], playSessionId: String, mediaSource: MediaSourceInfo, subtitleURLs: [SubtitleResourceItem], isDirectStream: Bool, routeNote: String) {
        self.streamURL = streamURL; self.headers = headers; self.playSessionId = playSessionId; self.mediaSource = mediaSource; self.subtitleURLs = subtitleURLs; self.isDirectStream = isDirectStream; self.routeNote = routeNote
    }
}

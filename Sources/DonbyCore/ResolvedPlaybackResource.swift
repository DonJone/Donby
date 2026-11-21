import Foundation

public struct SubtitleResourceItem: Sendable, Equatable, Hashable, Identifiable {
    public var id: String { "\(streamIndex ?? -1)|\(name)|\(url.absoluteString)" }
    public let name: String
    public let url: URL
    public let streamIndex: Int?
    public let codec: String?
    public let isExternal: Bool

    public init(
        name: String,
        url: URL,
        streamIndex: Int? = nil,
        codec: String? = nil,
        isExternal: Bool = true
    ) {
        self.name = name
        self.url = url
        self.streamIndex = streamIndex
        self.codec = codec
        self.isExternal = isExternal
    }
}

public struct ResolvedPlaybackResource: Sendable, Equatable {
    public let streamURL: URL
    public let originStreamURL: URL?
    public let downloadURL: URL?
    public let headers: [String: String]
    public let playSessionId: String
    public let mediaSource: MediaSourceInfo
    public let subtitleURLs: [SubtitleResourceItem]
    public let isDirectStream: Bool
    public let routeNote: String

    public init(streamURL: URL, originStreamURL: URL? = nil, downloadURL: URL? = nil, headers: [String: String], playSessionId: String, mediaSource: MediaSourceInfo, subtitleURLs: [SubtitleResourceItem], isDirectStream: Bool, routeNote: String) {
        self.streamURL = streamURL; self.originStreamURL = originStreamURL; self.downloadURL = downloadURL; self.headers = headers; self.playSessionId = playSessionId; self.mediaSource = mediaSource; self.subtitleURLs = subtitleURLs; self.isDirectStream = isDirectStream; self.routeNote = routeNote
    }
}

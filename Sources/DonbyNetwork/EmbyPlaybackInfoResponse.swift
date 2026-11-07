import Foundation
import DonbyCore

public struct EmbyPlaybackInfoResponse: Codable, Sendable {
    public let mediaSources: [MediaSourceInfo]?
    public let playSessionId: String?

    enum CodingKeys: String, CodingKey {
        case mediaSources = "MediaSources"; case playSessionId = "PlaySessionId"
    }

    public init(mediaSources: [MediaSourceInfo]? = nil, playSessionId: String? = nil) {
        self.mediaSources = mediaSources; self.playSessionId = playSessionId
    }
}

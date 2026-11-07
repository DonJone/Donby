import Foundation

public struct EmbyChapterInfo: Codable, Identifiable, Hashable, Sendable {
    public var id: Int64 { startPositionTicks ?? 0 }
    public let startPositionTicks: Int64?
    public let name: String?
    public let imageTag: String?

    enum CodingKeys: String, CodingKey {
        case startPositionTicks = "StartPositionTicks"; case name = "Name"; case imageTag = "ImageTag"
    }

    public init(startPositionTicks: Int64? = nil, name: String? = nil, imageTag: String? = nil) {
        self.startPositionTicks = startPositionTicks; self.name = name; self.imageTag = imageTag
    }

    public var startSeconds: Double { Double(startPositionTicks ?? 0) / 10_000_000.0 }
}

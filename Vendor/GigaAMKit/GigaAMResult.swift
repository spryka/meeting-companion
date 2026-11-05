import Foundation

public struct GigaAMResult: Sendable, Codable {
    public let text: String
    public let segments: [GigaAMSegment]
    /// Per-word timings derived from the RNNT greedy decoder's emission trace
    /// (one encoder frame of resolution, see `GigaAMProModel.encoderFrameDuration`).
    public let words: [GigaAMProWord]
    public let duration: TimeInterval?

    public init(
        text: String,
        segments: [GigaAMSegment] = [],
        words: [GigaAMProWord] = [],
        duration: TimeInterval? = nil
    ) {
        self.text = text
        self.segments = segments
        self.words = words
        self.duration = duration
    }
}

public struct GigaAMSegment: Sendable, Codable {
    public let text: String
    public let start: TimeInterval?
    public let end: TimeInterval?

    public init(
        text: String,
        start: TimeInterval? = nil,
        end: TimeInterval? = nil
    ) {
        self.text = text
        self.start = start
        self.end = end
    }
}

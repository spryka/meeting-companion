import Foundation
import MeetingCompanionCore

public struct PipelineError: Error, LocalizedError, CustomStringConvertible, Sendable {
    public let message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}

public struct ASRToken: Equatable, Sendable {
    public let id: Int
    public let piece: String
    public let start: Double
    public let end: Double
    public let frame: Int

    public init(id: Int, piece: String, start: Double, end: Double, frame: Int = 0) {
        self.id = id
        self.piece = piece
        self.start = start
        self.end = end
        self.frame = frame
    }
}

public struct DiarizationInterval: Equatable, Sendable {
    public let start: Double
    public let end: Double
    public let speaker: Int

    public init(start: Double, end: Double, speaker: Int) {
        self.start = start
        self.end = end
        self.speaker = speaker
    }
}

public struct PipelineWord: Equatable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public var speaker: Int?

    public init(start: Double, end: Double, text: String, speaker: Int? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.speaker = speaker
    }

    public func with(speaker: Int?) -> PipelineWord {
        PipelineWord(start: start, end: end, text: text, speaker: speaker)
    }

    public func with(text: String) -> PipelineWord {
        PipelineWord(start: start, end: end, text: text, speaker: speaker)
    }
}

public struct Suggestion: Equatable, Codable, Sendable {
    public var start: Double
    public var end: Double
    public var original: String
    public var proposed: String
    public var score: Double
    public var donor_start: Double
    public var donor_end: Double
    public var source_indices: [Int]
    public var donor_indices: [Int]
    public var time_overlap: Double
    public var applied: Bool
    public var reason: String

    public init(
        start: Double,
        end: Double,
        original: String,
        proposed: String,
        score: Double,
        donor_start: Double,
        donor_end: Double,
        source_indices: [Int],
        donor_indices: [Int],
        time_overlap: Double,
        applied: Bool,
        reason: String
    ) {
        self.start = start
        self.end = end
        self.original = original
        self.proposed = proposed
        self.score = score
        self.donor_start = donor_start
        self.donor_end = donor_end
        self.source_indices = source_indices
        self.donor_indices = donor_indices
        self.time_overlap = time_overlap
        self.applied = applied
        self.reason = reason
    }
}

public struct PipelineProgressEvent: Sendable {
    public let stage: TranscriptionProgress.Stage
    public let channel: String?
    public let completed: Int
    public let total: Int
    public let step: Int?
    public let steps: Int?
    public let warning: String?

    public init(
        stage: TranscriptionProgress.Stage,
        channel: String? = nil,
        completed: Int,
        total: Int,
        step: Int? = nil,
        steps: Int? = nil,
        warning: String? = nil
    ) {
        self.stage = stage
        self.channel = channel
        self.completed = completed
        self.total = total
        self.step = step
        self.steps = steps
        self.warning = warning
    }

    public func formatStdoutLine() -> String {
        var dict: [String: Any] = [
            "stage": stage.rawValue,
            "completed": completed,
            "total": total
        ]
        if let channel { dict["channel"] = channel }
        if let step { dict["step"] = step }
        if let steps { dict["steps"] = steps }
        if let warning { dict["warning"] = warning }
        if let data = try? JSONSerialization.data(withJSONObject: dict, options: [.sortedKeys]),
           let str = String(data: data, encoding: .utf8) {
            return "MEETING_PROGRESS " + str
        }
        return "MEETING_PROGRESS {\"completed\":\(completed),\"stage\":\"\(stage.rawValue)\",\"total\":\(total)}"
    }
}

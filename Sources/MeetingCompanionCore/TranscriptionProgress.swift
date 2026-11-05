import Foundation

public struct TranscriptionProgress: Decodable, Equatable, Sendable {
    public enum Stage: String, Decodable, Sendable {
        case gigaam, diarization, speakers, vad, parakeet, correction, merge, warning, echo
    }

    public let stage: Stage
    public let channel: String?
    public let completed: Int
    public let total: Int
    public let step: Int?
    public let steps: Int?
    public let warning: String?

    public init?(line: Data) {
        let prefix = Data("MEETING_PROGRESS ".utf8)
        guard line.starts(with: prefix),
              let value = try? JSONDecoder().decode(Self.self, from: line.dropFirst(prefix.count)),
              value.completed >= 0, value.total >= 0, value.completed <= value.total,
              value.channel == nil || value.channel == "host" || value.channel == "remote" else { return nil }
        guard (value.step == nil && value.steps == nil) ||
              (value.step != nil && value.steps != nil && value.step! > 0 && value.step! <= value.steps!) else { return nil }
        if value.stage == .warning && value.warning == nil { return nil }
        self = value
    }

    public init(stage: Stage, channel: String? = nil, completed: Int, total: Int, step: Int? = nil, steps: Int? = nil, warning: String? = nil) {
        self.stage = stage
        self.channel = channel
        self.completed = completed
        self.total = total
        self.step = step
        self.steps = steps
        self.warning = warning
    }

    public var completedSteps: Int? {
        guard let step else { return nil }
        return step - 1 + (total > 0 && completed == total ? 1 : 0)
    }

    public var stageFraction: Double? {
        total > 0 ? Double(completed) / Double(total) : nil
    }

    public var text: String {
        let label: String
        switch stage {
        case .echo: label = "Подавление эха"
        case .gigaam: label = "Распознавание GigaAM"
        case .vad: label = "Поиск речи"
        case .parakeet: label = "Распознавание Parakeet"
        case .correction: label = "Уточнение терминов"
        case .warning: label = warning ?? "Предупреждение"
        case .diarization: label = "Разделение голосов"
        case .speakers: label = "Назначение голосов словам"
        case .merge: label = "Объединение дорожек"
        }
        let source = channel.map { $0 == "host" ? " · микрофон" : " · системный звук" } ?? ""
        if stage == .echo {
            let count = stageFraction.map { " · \(Int($0 * 100))%" } ?? ""
            return label + source + count + "…"
        }
        let unit = stage == .speakers ? "слов" : "окон"
        let count = total > 1 ? " · \(completed)/\(total) \(unit)" : ""
        return label + source + count + "…"
    }
}

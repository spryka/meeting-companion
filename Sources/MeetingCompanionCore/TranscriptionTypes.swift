import Foundation

public enum TranscriptionState: Equatable, Sendable {
    case idle
    case running(TranscriptionProgress?)
    case completed(URL)
    case failed(String)

    public var transcript: URL? {
        if case .completed(let url) = self { return url }
        return nil
    }

    public var text: String {
        switch self {
        case .idle: return ""
        case .running(let progress): return progress?.text ?? "Подготовка транскрибации…"
        case .completed: return "Текст готов"
        case .failed(let message): return message
        }
    }
}

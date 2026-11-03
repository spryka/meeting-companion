import Foundation

public enum RecorderError: LocalizedError {
    case noDisplay
    case notConfigured
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)
    case unsupportedFileType(String, String)
    case exportUnavailable
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "Не найден экран для записи системного звука."
        case .notConfigured:
            return "Запись ещё не настроена."
        case .missingValue(let argument):
            return "Missing value for \(argument)."
        case .invalidValue(let argument, let value):
            return "Invalid value for \(argument): \(value)."
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument). Use --help."
        case .unsupportedFileType(let requested, let supported):
            return "Unsupported output file type: \(requested). Supported types: \(supported)"
        case .exportUnavailable:
            return "Не удалось подготовить сохранение звука в M4A."
        case .exportFailed:
            return "Не удалось сохранить звук в M4A."
        }
    }
}

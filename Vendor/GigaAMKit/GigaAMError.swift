import Foundation

public enum GigaAMError: Error, LocalizedError, Sendable {
    case fileNotFound(String)
    case modelDirectoryNotFound(String)
    case manifestNotFound(String)
    case weightsNotFound(String)
    case tokenizerNotFound(String)
    case invalidManifest(String)
    case invalidArguments(String)
    case notImplemented(String)

    public var errorDescription: String? {
        switch self {
        case .fileNotFound(let path):
            return "File not found: \(path)"
        case .modelDirectoryNotFound(let path):
            return "Model directory not found: \(path)"
        case .manifestNotFound(let path):
            return "Model manifest not found: \(path)"
        case .weightsNotFound(let path):
            return "Model weights not found: \(path)"
        case .tokenizerNotFound(let path):
            return "Tokenizer not found: \(path)"
        case .invalidManifest(let message):
            return "Invalid manifest: \(message)"
        case .invalidArguments(let message):
            return "Invalid arguments: \(message)"
        case .notImplemented(let message):
            return "Not implemented yet: \(message)"
        }
    }
}

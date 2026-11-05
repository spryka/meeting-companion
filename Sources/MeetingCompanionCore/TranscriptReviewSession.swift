import Foundation

public enum TranscriptReviewSessionError: LocalizedError, Equatable, Sendable {
    case closed
    public var errorDescription: String? { "Сеанс расшифровки закрыт" }
}

/// An editor is pinned to one immutable result until closed.
@MainActor
public final class TranscriptReviewSession {
    public let recordingDirectory: URL
    public let recordingURL: URL?
    public let activeResultID: String
    public let editsRepository: TranscriptEditsRepository
    public private(set) var isClosed = false

    public init(recordingDirectory: URL, recordingURL: URL? = nil, activeResultID: String,
                editsRepository: TranscriptEditsRepository) {
        self.recordingDirectory = recordingDirectory
        self.recordingURL = recordingURL
        self.activeResultID = activeResultID
        self.editsRepository = editsRepository
    }

    public static func open(recordingDirectory: URL, recordingURL: URL? = nil) throws -> TranscriptReviewSession? {
        if let recordingURL, !RecordingPaths.isStandardLayout(recordingURL) { return nil }
        guard let document = try TranscriptResultStorage(recordingDirectory: recordingDirectory,
                                                         recordingURL: recordingURL).currentDocument() else { return nil }
        return TranscriptReviewSession(recordingDirectory: recordingDirectory, recordingURL: recordingURL,
            activeResultID: document.resultID,
            editsRepository: TranscriptEditsRepository(recordingDirectory: recordingDirectory))
    }

    public static func open(recordingURL: URL) throws -> TranscriptReviewSession? {
        try open(recordingDirectory: recordingURL.deletingLastPathComponent(), recordingURL: recordingURL)
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        editsRepository.releaseWriteLock()
    }
}

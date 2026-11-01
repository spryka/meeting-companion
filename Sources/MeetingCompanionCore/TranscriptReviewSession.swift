import Foundation

public enum TranscriptReviewSessionError: LocalizedError, Equatable, Sendable {
    case closed

    public var errorDescription: String? {
        "Сеанс расшифровки закрыт"
    }
}

/// Core open session for viewing and editing transcript recognition results with version pinning.
@MainActor
public final class TranscriptReviewSession {
    public typealias PersistSelectionHandler = @MainActor @Sendable (_ resultID: String) throws -> Void

    public let recordingDirectory: URL
    public let recordingURL: URL?
    public let selector: TranscriptVersionSelector
    public let editsRepository: TranscriptEditsRepository
    public var onPersistSelection: PersistSelectionHandler?

    private var _activeResultID: String
    private var isSwitching = false
    public private(set) var isClosed = false

    public var activeResultID: String {
        _activeResultID
    }

    public init(
        recordingDirectory: URL,
        recordingURL: URL? = nil,
        activeResultID: String,
        selector: TranscriptVersionSelector,
        editsRepository: TranscriptEditsRepository,
        onPersistSelection: PersistSelectionHandler? = nil
    ) {
        self.recordingDirectory = recordingDirectory
        self.recordingURL = recordingURL
        self._activeResultID = activeResultID
        self.selector = selector
        self.editsRepository = editsRepository
        self.onPersistSelection = onPersistSelection
    }

    /// Opens a review session for the recording, pinning the initially resolved version.
    /// Returns `nil` if no valid published versions exist for the recording.
    public static func open(
        recordingDirectory: URL,
        recordingURL: URL? = nil,
        onPersistSelection: PersistSelectionHandler? = nil
    ) throws -> TranscriptReviewSession? {
        let selector = TranscriptVersionSelector(
            recordingDirectory: recordingDirectory,
            recordingURL: recordingURL
        )
        guard let initialResultID = try selector.resolveSelectedResultID() else {
            return nil
        }
        let editsRepo = TranscriptEditsRepository(recordingDirectory: recordingDirectory)
        return TranscriptReviewSession(
            recordingDirectory: recordingDirectory,
            recordingURL: recordingURL,
            activeResultID: initialResultID,
            selector: selector,
            editsRepository: editsRepo,
            onPersistSelection: onPersistSelection
        )
    }

    /// Opens a review session for the recording URL, pinning the initially resolved version.
    /// Returns `nil` if no valid published versions exist for the recording.
    public static func open(
        recordingURL: URL,
        onPersistSelection: PersistSelectionHandler? = nil
    ) throws -> TranscriptReviewSession? {
        try open(
            recordingDirectory: recordingURL.deletingLastPathComponent(),
            recordingURL: recordingURL,
            onPersistSelection: onPersistSelection
        )
    }

    /// Closes the session, releasing any persistence handlers and preventing further version switches.
    public func close() {
        isClosed = true
        onPersistSelection = nil
    }

    /// Persists the selection before switching the active version of a live session.
    /// If persistence fails, the version is unavailable, or the callback closes the session,
    /// `activeResultID` remains unchanged. Completed persistence is not rolled back on closure.
    public func switchVersion(to newResultID: String) throws {
        guard !isClosed else {
            throw TranscriptReviewSessionError.closed
        }
        guard !isSwitching else {
            throw TranscriptVersionSelectionError.malformedMetadata("Reentrant version switch is not allowed")
        }
        guard newResultID != _activeResultID else { return }

        let available = try selector.availableVersions()
        guard available.contains(where: { $0.resultID == newResultID }) else {
            throw TranscriptVersionSelectionError.selectedVersionUnavailable(newResultID)
        }

        isSwitching = true
        defer { isSwitching = false }

        // Persist through injected authoritative handler or selector
        if let handler = onPersistSelection {
            try handler(newResultID)
        } else {
            try selector.persistSelectedResultID(newResultID)
        }

        // The synchronous callback may close this session after persisting the selection.
        guard !isClosed else {
            throw TranscriptReviewSessionError.closed
        }

        // Mutate session state only after successful persistence while still open.
        self._activeResultID = newResultID
    }
}

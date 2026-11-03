import Foundation

public enum TranscriptWindowError: LocalizedError, Equatable, Sendable {
    case transcriptNotFound(String)
    case pathEscapesRecording(String)
    case readOnlyLegacy(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .transcriptNotFound(let detail): "Расшифровка не найдена: \(detail)"
        case .pathEscapesRecording(let detail): "Небезопасный путь: \(detail)"
        case .readOnlyLegacy(let detail): "Редактирование недоступно в режиме чтения старого TXT: \(detail)"
        case .closed: "Окно расшифровки закрыто"
        }
    }
}

@MainActor
public final class TranscriptWindowState: Identifiable {
    public enum Mode: Equatable, Sendable {
        case review(activeResultID: String)
        case legacyReadOnly(transcriptURL: URL)
        case corrupt(error: String, fallbackTranscriptURL: URL?)
    }

    public let id: URL
    public let recordingDirectory: URL
    public let recordingURL: URL
    public private(set) var mode: Mode
    public private(set) var session: TranscriptReviewSession?
    public private(set) var legacyTranscriptURL: URL?
    public private(set) var focusRequestedCount: Int = 0
    public private(set) var isClosed: Bool = false

    weak var coordinator: TranscriptWindowCoordinator?

    public var isReadOnly: Bool {
        switch mode {
        case .review: false
        case .legacyReadOnly, .corrupt: true
        }
    }

    public var activeResultID: String? {
        session?.activeResultID
    }

    public init(
        id: URL,
        recordingDirectory: URL,
        recordingURL: URL,
        mode: Mode,
        session: TranscriptReviewSession? = nil,
        legacyTranscriptURL: URL? = nil,
        coordinator: TranscriptWindowCoordinator? = nil
    ) {
        self.id = id
        self.recordingDirectory = recordingDirectory
        self.recordingURL = recordingURL
        self.mode = mode
        self.session = session
        self.legacyTranscriptURL = legacyTranscriptURL
        self.coordinator = coordinator
    }

    func requestFocus() {
        focusRequestedCount += 1
    }

    public func close() {
        guard !isClosed else { return }
        isClosed = true
        session?.close()
        session = nil
        coordinator?.closeWindow(instance: self)
        coordinator = nil
    }
}

@MainActor
public final class TranscriptWindowCoordinator {

    public private(set) var openWindows: [URL: TranscriptWindowState] = [:]

    public init() {}

    public static func canonicalURL(for url: URL) -> URL {
        let standard = url.standardizedFileURL
        if standard.hasDirectoryPath {
            return standard.resolvingSymlinksInPath()
        } else {
            let parent = standard.deletingLastPathComponent().resolvingSymlinksInPath()
            return parent.appendingPathComponent(standard.lastPathComponent)
        }
    }

    public func isWindowOpen(for recordingURL: URL) -> Bool {
        let key = Self.canonicalURL(for: recordingURL)
        return openWindows[key] != nil
    }

    public func windowState(for recordingURL: URL) -> TranscriptWindowState? {
        let key = Self.canonicalURL(for: recordingURL)
        return openWindows[key]
    }

    public func closeWindow(instance: TranscriptWindowState) {
        let key = instance.id
        if openWindows[key] === instance {
            openWindows.removeValue(forKey: key)
        }
        instance.close()
    }

    public func closeWindow(for recordingURL: URL) {
        let key = Self.canonicalURL(for: recordingURL)
        if let state = openWindows[key] {
            openWindows.removeValue(forKey: key)
            state.close()
        }
    }

    public func closeAll() {
        let states = Array(openWindows.values)
        openWindows.removeAll()
        for state in states {
            state.close()
        }
    }

    private struct Assessment: Sendable {
        let recording: URL
        let mode: TranscriptWindowState.Mode
    }

    public func openWindow(
        for recordingURL: URL
    ) async throws -> (state: TranscriptWindowState, isNew: Bool) {
        let key = await Task.detached { RecordingEntry.canonicalURL(recordingURL) }.value
        if let existing = openWindows[key] {
            existing.requestFocus()
            return (existing, false)
        }
        let assessment = try await Task.detached {
            try Self.assess(key)
        }.value
        let recording = assessment.recording
        if let existing = openWindows[recording] {
            existing.requestFocus()
            return (existing, false)
        }
        let directory = recording.deletingLastPathComponent()
        var session: TranscriptReviewSession?
        if case .review(let id) = assessment.mode {
            session = TranscriptReviewSession(recordingDirectory: directory, recordingURL: recording,
                activeResultID: id,
                editsRepository: TranscriptEditsRepository(recordingDirectory: directory))
        }
        let text: URL?
        switch assessment.mode {
        case .review: text = nil
        case .legacyReadOnly(let url): text = url
        case .corrupt(_, let url): text = url
        }
        let state = TranscriptWindowState(id: recording, recordingDirectory: directory,
            recordingURL: recording, mode: assessment.mode, session: session,
            legacyTranscriptURL: text, coordinator: self)
        openWindows[recording] = state
        return (state, true)
    }

    nonisolated private static func assess(_ url: URL) throws -> Assessment {
        let recording = RecordingEntry.canonicalURL(url)
        let directory = recording.deletingLastPathComponent()
        func assessed(_ mode: TranscriptWindowState.Mode) -> Assessment { Assessment(recording: recording, mode: mode) }
        var structuredError: String?
        do {
            if RecordingPaths.isStandardLayout(recording), let document = try TranscriptResultStorage(recordingURL: recording).currentDocument() {
                return assessed(.review(activeResultID: document.resultID))
            }
        } catch let error as TranscriptStorageError {
            if case .pathEscapesRecording(let detail) = error { throw TranscriptWindowError.pathEscapesRecording(detail) }
            structuredError = error.localizedDescription
        } catch { structuredError = error.localizedDescription }
        let fm = FileManager.default
        let textURL = recording.deletingPathExtension().appendingPathExtension("sources.transcript.txt")
        var text: URL?
        var isDirectory: ObjCBool = false
        if fm.fileExists(atPath: textURL.path, isDirectory: &isDirectory), !isDirectory.boolValue {
            let resolved = textURL.resolvingSymlinksInPath().standardizedFileURL
            guard resolved.path.hasPrefix(directory.path + "/"), fm.fileExists(atPath: resolved.path) else {
                throw TranscriptWindowError.pathEscapesRecording(textURL.path)
            }
            text = textURL
        } else {
            var status = stat()
            if lstat(textURL.path, &status) == 0 {
                throw TranscriptWindowError.pathEscapesRecording("Legacy transcript is a dangling symlink: " + textURL.path)
            }
        }
        if let structuredError { return assessed(.corrupt(error: structuredError, fallbackTranscriptURL: text)) }
        if let text { return assessed(.legacyReadOnly(transcriptURL: text)) }
        throw TranscriptWindowError.transcriptNotFound(recording.path)
    }
}

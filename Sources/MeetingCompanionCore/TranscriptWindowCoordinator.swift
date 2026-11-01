import Foundation

public enum TranscriptWindowError: LocalizedError, Equatable, Sendable {
    case transcriptNotFound(String)
    case pathEscapesRecording(String)
    case corruptStructuredResult(String)
    case selectedVersionUnavailable(String)
    case readOnlyLegacy(String)
    case closed

    public var errorDescription: String? {
        switch self {
        case .transcriptNotFound(let detail): "Расшифровка не найдена: \(detail)"
        case .pathEscapesRecording(let detail): "Небезопасный путь: \(detail)"
        case .corruptStructuredResult(let detail): "Структурированный результат повреждён: \(detail)"
        case .selectedVersionUnavailable(let version): "Выбранная версия \(version) недоступна"
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
        case unavailable(version: String, fallbackTranscriptURL: URL?)
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
        case .legacyReadOnly, .unavailable, .corrupt: true
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

    public func switchVersion(to newResultID: String) throws {
        guard !isClosed else {
            throw TranscriptWindowError.closed
        }
        guard let session = session else {
            throw TranscriptWindowError.readOnlyLegacy("Cannot switch version in legacy, unavailable, or corrupt mode")
        }
        try session.switchVersion(to: newResultID)
        guard !isClosed, !session.isClosed else {
            throw TranscriptWindowError.closed
        }
        self.mode = .review(activeResultID: newResultID)
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
    public typealias PersistSelectionHandler = TranscriptReviewSession.PersistSelectionHandler

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

    public func openWindow(
        for recordingURL: URL,
        onPersistSelection: PersistSelectionHandler? = nil
    ) throws -> (state: TranscriptWindowState, isNew: Bool) {
        let canonicalRecording = Self.canonicalURL(for: recordingURL)
        let canonicalDir = canonicalRecording.deletingLastPathComponent()

        // 1. If already open, request focus on existing instance
        if let existing = openWindows[canonicalRecording] {
            existing.requestFocus()
            return (state: existing, isNew: false)
        }

        // 2. Validate directory containment
        guard canonicalRecording.path.hasPrefix(canonicalDir.path + "/") || canonicalRecording.path == canonicalDir.path else {
            throw TranscriptWindowError.pathEscapesRecording("Recording URL escapes recording directory: \(recordingURL.path)")
        }

        let fm = FileManager.default

        // 3. Check for legacy TXT transcript with strict final-target containment check
        let legacyTXT = canonicalRecording.deletingPathExtension().appendingPathExtension("sources.transcript.txt")
        var verifiedLegacyTXTURL: URL? = nil

        var isDir: ObjCBool = false
        if fm.fileExists(atPath: legacyTXT.path, isDirectory: &isDir), !isDir.boolValue {
            // Resolve final physical destination of the legacy TXT
            let realTXT = legacyTXT.resolvingSymlinksInPath().standardizedFileURL
            guard realTXT.path.hasPrefix(canonicalDir.path + "/") else {
                throw TranscriptWindowError.pathEscapesRecording("Legacy transcript escapes recording directory: \(legacyTXT.path) -> \(realTXT.path)")
            }
            guard fm.fileExists(atPath: realTXT.path) else {
                throw TranscriptWindowError.pathEscapesRecording("Legacy transcript target does not exist or is dangling")
            }
            verifiedLegacyTXTURL = legacyTXT
        } else {
            var statBuf = stat()
            if lstat(legacyTXT.path, &statBuf) == 0 {
                // Symlink exists but fileExists was false -> dangling symlink
                throw TranscriptWindowError.pathEscapesRecording("Legacy transcript is a dangling symlink: \(legacyTXT.path)")
            }
        }

        let selector = TranscriptVersionSelector(
            recordingDirectory: canonicalDir,
            recordingURL: canonicalRecording
        )

        // 4. Check for persisted selected version in metadata before legacy fallback (never suppress errors)
        let persistedSelectedID: String?
        do {
            persistedSelectedID = try selector.persistedSelectedResultID()
        } catch let error as TranscriptVersionSelectionError {
            switch error {
            case .pathEscapesRecording(let detail):
                throw TranscriptWindowError.pathEscapesRecording(detail)
            default:
                let errorMsg = error.localizedDescription
                if let fallbackTXT = verifiedLegacyTXTURL {
                    let state = TranscriptWindowState(
                        id: canonicalRecording,
                        recordingDirectory: canonicalDir,
                        recordingURL: canonicalRecording,
                        mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                        legacyTranscriptURL: fallbackTXT,
                        coordinator: self
                    )
                    openWindows[canonicalRecording] = state
                    return (state: state, isNew: true)
                } else {
                    throw TranscriptWindowError.corruptStructuredResult(errorMsg)
                }
            }
        } catch {
            let errorMsg = error.localizedDescription
            if let fallbackTXT = verifiedLegacyTXTURL {
                let state = TranscriptWindowState(
                    id: canonicalRecording,
                    recordingDirectory: canonicalDir,
                    recordingURL: canonicalRecording,
                    mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                    legacyTranscriptURL: fallbackTXT,
                    coordinator: self
                )
                openWindows[canonicalRecording] = state
                return (state: state, isNew: true)
            } else {
                throw TranscriptWindowError.corruptStructuredResult(errorMsg)
            }
        }

        // 5. Discover structured versions through selector with explicit error handling (never suppress errors)
        let availableVersions: [TranscriptVersionInfo]
        do {
            availableVersions = try selector.availableVersions()
        } catch let error as TranscriptVersionSelectionError {
            switch error {
            case .pathEscapesRecording(let detail):
                throw TranscriptWindowError.pathEscapesRecording(detail)
            default:
                let errorMsg = error.localizedDescription
                if let fallbackTXT = verifiedLegacyTXTURL {
                    let state = TranscriptWindowState(
                        id: canonicalRecording,
                        recordingDirectory: canonicalDir,
                        recordingURL: canonicalRecording,
                        mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                        legacyTranscriptURL: fallbackTXT,
                        coordinator: self
                    )
                    openWindows[canonicalRecording] = state
                    return (state: state, isNew: true)
                } else {
                    throw TranscriptWindowError.corruptStructuredResult(errorMsg)
                }
            }
        } catch {
            let errorMsg = error.localizedDescription
            if let fallbackTXT = verifiedLegacyTXTURL {
                let state = TranscriptWindowState(
                    id: canonicalRecording,
                    recordingDirectory: canonicalDir,
                    recordingURL: canonicalRecording,
                    mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                    legacyTranscriptURL: fallbackTXT,
                    coordinator: self
                )
                openWindows[canonicalRecording] = state
                return (state: state, isNew: true)
            } else {
                throw TranscriptWindowError.corruptStructuredResult(errorMsg)
            }
        }

        // 6. Check for structured version directory raw/transcripts/
        let transcriptsDir = canonicalDir.appendingPathComponent("raw/transcripts")
        var hasStructuredCandidates = false
        if fm.fileExists(atPath: transcriptsDir.path) {
            do {
                let entries = try fm.contentsOfDirectory(atPath: transcriptsDir.path)
                let candidates = entries.filter {
                    !$0.hasPrefix("staging") && !$0.hasPrefix(".") && !$0.contains(".tmp")
                }
                hasStructuredCandidates = !candidates.isEmpty
            } catch {
                let errorMsg = "Не удалось прочитать каталог версий: \(error.localizedDescription)"
                if let fallbackTXT = verifiedLegacyTXTURL {
                    let state = TranscriptWindowState(
                        id: canonicalRecording,
                        recordingDirectory: canonicalDir,
                        recordingURL: canonicalRecording,
                        mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                        legacyTranscriptURL: fallbackTXT,
                        coordinator: self
                    )
                    openWindows[canonicalRecording] = state
                    return (state: state, isNew: true)
                } else {
                    throw TranscriptWindowError.corruptStructuredResult(errorMsg)
                }
            }
        }

        // 7. Handle explicit persisted selected version if one was saved
        if let explicitID = persistedSelectedID {
            if !availableVersions.contains(where: { $0.resultID == explicitID }) {
                // Explicit saved selection is missing: preserve .unavailable classification
                if let fallbackTXT = verifiedLegacyTXTURL {
                    let state = TranscriptWindowState(
                        id: canonicalRecording,
                        recordingDirectory: canonicalDir,
                        recordingURL: canonicalRecording,
                        mode: .unavailable(version: explicitID, fallbackTranscriptURL: fallbackTXT),
                        legacyTranscriptURL: fallbackTXT,
                        coordinator: self
                    )
                    openWindows[canonicalRecording] = state
                    return (state: state, isNew: true)
                } else {
                    throw TranscriptWindowError.selectedVersionUnavailable(explicitID)
                }
            }
        }

        // 8. If no structured candidates exist and no missing explicit selection
        if !hasStructuredCandidates {
            if let legacyURL = verifiedLegacyTXTURL {
                let state = TranscriptWindowState(
                    id: canonicalRecording,
                    recordingDirectory: canonicalDir,
                    recordingURL: canonicalRecording,
                    mode: .legacyReadOnly(transcriptURL: legacyURL),
                    legacyTranscriptURL: legacyURL,
                    coordinator: self
                )
                openWindows[canonicalRecording] = state
                return (state: state, isNew: true)
            } else {
                throw TranscriptWindowError.transcriptNotFound("Расшифровка не найдена: \(recordingURL.path)")
            }
        }

        // 9. Structured candidates exist: attempt to open structured review session with canonical paths
        do {
            if let session = try TranscriptReviewSession.open(
                recordingDirectory: canonicalDir,
                recordingURL: canonicalRecording,
                onPersistSelection: onPersistSelection
            ) {
                let state = TranscriptWindowState(
                    id: canonicalRecording,
                    recordingDirectory: canonicalDir,
                    recordingURL: canonicalRecording,
                    mode: .review(activeResultID: session.activeResultID),
                    session: session,
                    coordinator: self
                )
                openWindows[canonicalRecording] = state
                return (state: state, isNew: true)
            } else {
                let errorMsg = "Структурированные результаты повреждены"
                if let fallbackTXT = verifiedLegacyTXTURL {
                    let state = TranscriptWindowState(
                        id: canonicalRecording,
                        recordingDirectory: canonicalDir,
                        recordingURL: canonicalRecording,
                        mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                        legacyTranscriptURL: fallbackTXT,
                        coordinator: self
                    )
                    openWindows[canonicalRecording] = state
                    return (state: state, isNew: true)
                } else {
                    throw TranscriptWindowError.corruptStructuredResult(errorMsg)
                }
            }
        } catch let error as TranscriptVersionSelectionError {
            switch error {
            case .pathEscapesRecording(let detail):
                throw TranscriptWindowError.pathEscapesRecording(detail)
            case .selectedVersionUnavailable(let version):
                if let fallbackTXT = verifiedLegacyTXTURL {
                    let state = TranscriptWindowState(
                        id: canonicalRecording,
                        recordingDirectory: canonicalDir,
                        recordingURL: canonicalRecording,
                        mode: .unavailable(version: version, fallbackTranscriptURL: fallbackTXT),
                        legacyTranscriptURL: fallbackTXT,
                        coordinator: self
                    )
                    openWindows[canonicalRecording] = state
                    return (state: state, isNew: true)
                } else {
                    throw TranscriptWindowError.selectedVersionUnavailable(version)
                }
            default:
                let errorMsg = error.localizedDescription
                if let fallbackTXT = verifiedLegacyTXTURL {
                    let state = TranscriptWindowState(
                        id: canonicalRecording,
                        recordingDirectory: canonicalDir,
                        recordingURL: canonicalRecording,
                        mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                        legacyTranscriptURL: fallbackTXT,
                        coordinator: self
                    )
                    openWindows[canonicalRecording] = state
                    return (state: state, isNew: true)
                } else {
                    throw TranscriptWindowError.corruptStructuredResult(errorMsg)
                }
            }
        } catch let error as TranscriptDocument.LoadError {
            if case .invalidPath(let detail) = error {
                throw TranscriptWindowError.pathEscapesRecording(detail)
            }
            let errorMsg = error.localizedDescription
            if let fallbackTXT = verifiedLegacyTXTURL {
                let state = TranscriptWindowState(
                    id: canonicalRecording,
                    recordingDirectory: canonicalDir,
                    recordingURL: canonicalRecording,
                    mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                    legacyTranscriptURL: fallbackTXT,
                    coordinator: self
                )
                openWindows[canonicalRecording] = state
                return (state: state, isNew: true)
            } else {
                throw TranscriptWindowError.corruptStructuredResult(errorMsg)
            }
        } catch {
            let errorMsg = error.localizedDescription
            if let fallbackTXT = verifiedLegacyTXTURL {
                let state = TranscriptWindowState(
                    id: canonicalRecording,
                    recordingDirectory: canonicalDir,
                    recordingURL: canonicalRecording,
                    mode: .corrupt(error: errorMsg, fallbackTranscriptURL: fallbackTXT),
                    legacyTranscriptURL: fallbackTXT,
                    coordinator: self
                )
                openWindows[canonicalRecording] = state
                return (state: state, isNew: true)
            } else {
                throw TranscriptWindowError.corruptStructuredResult(errorMsg)
            }
        }
    }
}

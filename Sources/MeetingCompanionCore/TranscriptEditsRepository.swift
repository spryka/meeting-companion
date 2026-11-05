import Foundation

/// Per-turn user overrides stored in `edits.json`.
public struct TranscriptTurnOverride: Codable, Equatable, Sendable {
    public var text: String?
    public var displayName: String?

    public init(text: String? = nil, displayName: String? = nil) {
        self.text = text
        self.displayName = displayName
    }
}

/// Durable user edits metadata and turn overrides associated with a specific recognition resultID.
public struct TranscriptEdits: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let resultID: String
    public let revision: Int
    public let overrides: [String: TranscriptTurnOverride]

    public init(
        schemaVersion: Int = 1,
        resultID: String,
        revision: Int,
        overrides: [String: TranscriptTurnOverride]
    ) {
        self.schemaVersion = schemaVersion
        self.resultID = resultID
        self.revision = revision
        self.overrides = overrides
    }

    public static func initial(resultID: String) -> TranscriptEdits {
        TranscriptEdits(schemaVersion: 1, resultID: resultID, revision: 0, overrides: [:])
    }
}

/// Errors occurring during transcript edits operations.
public enum TranscriptEditsError: LocalizedError, Sendable, Equatable {
    case notImplemented
    case unsupportedVersion(Int)
    case malformed(String)
    case resultNotFound(String)
    case invalidReference(String)
    case conflict(String)
    case lockDenied(String)
    case noUndoHistory(String)

    public var errorDescription: String? {
        switch self {
        case .notImplemented:
            return "Функция сохранения и чтения правок ещё не реализована"
        case .unsupportedVersion(let version):
            return "Версия правок \(version) не поддерживается"
        case .malformed(let detail):
            return "Некорректный файл правок: \(detail)"
        case .resultNotFound(let resultID):
            return "Результат не найден: \(resultID)"
        case .invalidReference(let detail):
            return "Некорректная ссылка в правках: \(detail)"
        case .conflict(let detail):
            return "Конфликт сохранения: \(detail)"
        case .lockDenied(let detail):
            return "Запись уже открыта для редактирования другим процессом: \(detail)"
        case .noUndoHistory(let detail):
            return "Нет истории правок для отмены: \(detail)"
        }
    }
}

/// Production repository managing durable user edits for transcript recognition results.
public final class TranscriptEditsRepository: @unchecked Sendable {
    /// Hook for intercepting or injecting failures during atomic file replacement in tests.
    public typealias AtomicReplaceHook = @Sendable (_ temporaryURL: URL, _ destinationURL: URL) throws -> Void
    /// Hook for injecting failures or partial writes during low-level staging write in tests.
    public typealias StagingWriteHook = @Sendable (_ fd: Int32, _ data: Data) throws -> Void

    /// In-memory snapshot of loaded edits on disk for CAS conflict detection in later stages.
    public struct LoadedSnapshot: Sendable {
        public let edits: TranscriptEdits
        public let data: Data?
        public let exists: Bool
    }

    public let recordingDirectory: URL
    public let atomicReplaceHook: AtomicReplaceHook?
    public let stagingWriteHook: StagingWriteHook?

    private let lock = NSLock()
    private let operationGate = NSLock()
    internal enum GateOperation: Sendable { case save, load, release, undo }
    private var operationGateObserver: (@Sendable (GateOperation) -> Void)?
    private var snapshots: [String: LoadedSnapshot] = [:]
    private var undoHistory: [String: [[String: TranscriptTurnOverride]]] = [:]
    private var lockFD: Int32? = nil

    public init(
        recordingDirectory: URL,
        atomicReplaceHook: AtomicReplaceHook? = nil,
        stagingWriteHook: StagingWriteHook? = nil
    ) {
        self.recordingDirectory = recordingDirectory
        self.atomicReplaceHook = atomicReplaceHook
        self.stagingWriteHook = stagingWriteHook
    }

    deinit {
        releaseWriteLock()
    }

    /// Test-only observation of an actual failed acquisition, not worker scheduling.
    internal convenience init(
        recordingDirectory: URL,
        operationGateObserver: @escaping @Sendable (GateOperation) -> Void,
        atomicReplaceHook: AtomicReplaceHook? = nil
    ) {
        self.init(recordingDirectory: recordingDirectory, atomicReplaceHook: atomicReplaceHook)
        self.operationGateObserver = operationGateObserver
    }

    private func acquireOperationGate(_ operation: GateOperation) {
        guard let observer = operationGateObserver else {
            operationGate.lock()
            return
        }
        if operationGate.try() { return }
        observer(operation)
        operationGate.lock()
    }

    /// URL of `edits.json` for the given version directory.
    public func editsURL(for resultID: String) -> URL {
        recordingDirectory
            .appendingPathComponent("raw")
            .appendingPathComponent("transcripts")
            .appendingPathComponent(resultID)
            .appendingPathComponent("edits.json")
    }

    /// URL of immutable `result.json` for the given version directory.
    public func resultURL(for resultID: String) -> URL {
        recordingDirectory
            .appendingPathComponent("raw")
            .appendingPathComponent("transcripts")
            .appendingPathComponent(resultID)
            .appendingPathComponent("result.json")
    }

    /// URL of the lock file for the recording directory.
    public func lockURL() -> URL {
        recordingDirectory.appendingPathComponent(".transcript-editor.lock")
    }

    /// Acquires exclusive writer lock for the recording directory.
    ///
    /// Throws `TranscriptEditsError.lockDenied` if already locked by another process.
    public func acquireWriteLock() throws {
        try lock.withLock {
            if lockFD != nil {
                return
            }

            let realRecordingURL = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL
            let lockFile = lockURL()
            guard isContained(fileURL: lockFile, within: realRecordingURL) else {
                throw TranscriptEditsError.malformed("Lock file path escapes recording directory")
            }

            #if canImport(Darwin)
            let fd = open(lockFile.path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
            if fd < 0 {
                let err = errno
                if err == ELOOP {
                    throw TranscriptEditsError.malformed("Lock file is a symlink escaping recording directory")
                }
                throw TranscriptEditsError.malformed("Cannot open lock file: errno \(err)")
            }

            let flockRes = flock(fd, LOCK_EX | LOCK_NB)
            if flockRes != 0 {
                let err = errno
                close(fd)
                if err == EWOULDBLOCK || err == EAGAIN {
                    throw TranscriptEditsError.lockDenied("Recording is locked by another writer")
                }
                throw TranscriptEditsError.malformed("flock failed with errno \(err)")
            }

            self.lockFD = fd
            #else
            throw TranscriptEditsError.notImplemented
            #endif
        }
    }

    /// Releases exclusive writer lock for the recording directory.
    public func releaseWriteLock() {
        acquireOperationGate(.release)
        defer { operationGate.unlock() }
        lock.withLock {
            #if canImport(Darwin)
            if let fd = lockFD {
                _ = flock(fd, LOCK_UN)
                close(fd)
                self.lockFD = nil
            }
            #endif
        }
    }

    /// Returns the snapshot captured during the last loadEdits call for the given resultID.
    public func loadedSnapshot(for resultID: String) -> LoadedSnapshot? {
        lock.withLock { snapshots[resultID] }
    }

    private func isContained(fileURL: URL, within parentURL: URL) -> Bool {
        let parentComponents = parentURL.standardizedFileURL.pathComponents
        let fileComponents = fileURL.standardizedFileURL.pathComponents
        guard fileComponents.count >= parentComponents.count else { return false }
        for i in 0..<parentComponents.count {
            if fileComponents[i] != parentComponents[i] {
                return false
            }
        }
        return true
    }

    /// Verifies that every component in the ancestor chain up to the target file resides strictly
    /// within `recordingDirectory`, resolving symlinks at each step and rejecting escaping or dangling links.
    private func verifyContainedPath(
        components: [String],
        allowFinalAbsence: Bool
    ) throws -> (url: URL, exists: Bool) {
        let realRecordingURL = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL
        var current = realRecordingURL

        for (index, component) in components.enumerated() {
            let isFinal = (index == components.count - 1)
            let next = current.appendingPathComponent(component)

            #if canImport(Darwin)
            var st = stat()
            let res = lstat(next.path, &st)
            if res != 0 {
                let err = errno
                if err == ENOENT {
                    if isFinal && allowFinalAbsence {
                        return (next, false)
                    }
                    throw TranscriptEditsError.resultNotFound("Component missing: \(component)")
                }
                throw TranscriptEditsError.malformed("lstat failed with errno \(err) for \(component)")
            }

            if (st.st_mode & S_IFMT) == S_IFLNK {
                let resolved = next.resolvingSymlinksInPath().standardizedFileURL
                guard isContained(fileURL: resolved, within: realRecordingURL) else {
                    throw TranscriptEditsError.malformed("Symlink escapes recording directory at \(component)")
                }
                guard FileManager.default.fileExists(atPath: resolved.path) else {
                    throw TranscriptEditsError.malformed("Dangling symlink at \(component)")
                }
                current = resolved
            } else {
                current = next.standardizedFileURL
                guard isContained(fileURL: current, within: realRecordingURL) else {
                    throw TranscriptEditsError.malformed("Path component escapes recording directory at \(component)")
                }
            }
            #else
            guard isContained(fileURL: next, within: realRecordingURL) else {
                throw TranscriptEditsError.resultNotFound(component)
            }
            current = next
            #endif
        }

        return (current, true)
    }

    /// Scans top-level string key and extracts its raw literal token from JSON bytes.
    /// Handles strings, backslash escapes, brace nesting, and rejects duplicate top-level keys.
    private static func scanTopLevelToken(data: Data, targetKey: String) throws -> String? {
        let n = data.count
        var i = 0

        func skipWhitespace() {
            while i < n {
                let b = data[i]
                if b == 0x20 || b == 0x09 || b == 0x0A || b == 0x0D {
                    i += 1
                } else {
                    break
                }
            }
        }

        func parseString() -> String? {
            guard i < n, data[i] == 0x22 else { return nil }
            let start = i
            i += 1
            while i < n {
                let b = data[i]
                if b == 0x22 {
                    i += 1
                    // Decode the original quoted token so every JSON escape and UTF-8
                    // scalar has the same meaning as in the document decoder.
                    return try? JSONDecoder().decode(String.self, from: Data(data[start..<i]))
                }
                if b == 0x5C {
                    i += 1
                    guard i < n else { return nil }
                }
                i += 1
            }
            return nil
        }

        func skipValue() -> Bool {
            skipWhitespace()
            guard i < n else { return false }
            let b = data[i]
            if b == 0x22 {
                return parseString() != nil
            } else if b == 0x7B {
                i += 1
                var depth = 1
                while i < n && depth > 0 {
                    let c = data[i]
                    if c == 0x22 {
                        guard parseString() != nil else { return false }
                    } else {
                        if c == 0x7B { depth += 1 }
                        else if c == 0x7D { depth -= 1 }
                        i += 1
                    }
                }
                return depth == 0
            } else if b == 0x5B {
                i += 1
                var depth = 1
                while i < n && depth > 0 {
                    let c = data[i]
                    if c == 0x22 {
                        guard parseString() != nil else { return false }
                    } else {
                        if c == 0x5B { depth += 1 }
                        else if c == 0x5D { depth -= 1 }
                        i += 1
                    }
                }
                return depth == 0
            } else {
                while i < n && data[i] != 0x2C && data[i] != 0x7D && data[i] != 0x5D && data[i] > 0x20 {
                    i += 1
                }
                return true
            }
        }

        skipWhitespace()
        guard i < n, data[i] == 0x7B else { return nil }
        i += 1

        var found: String? = nil
        while i < n {
            skipWhitespace()
            if i < n && data[i] == 0x7D { break }
            guard let key = parseString() else { return nil }
            skipWhitespace()
            guard i < n, data[i] == 0x3A else { return nil }
            i += 1
            skipWhitespace()

            if key == targetKey {
                if found != nil {
                    throw TranscriptEditsError.malformed("Duplicate top-level key: \(targetKey)")
                }
                let start = i
                guard skipValue() else { return nil }
                let rawToken = String(decoding: data[start..<i], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                found = rawToken
            } else {
                guard skipValue() else { return nil }
            }

            skipWhitespace()
            if i < n && data[i] == 0x2C {
                i += 1
            } else if i < n && data[i] == 0x7D {
                break
            }
        }
        return found
    }

    private static func parseExactNonnegativeInteger(token: String) -> Int? {
        guard !token.isEmpty else { return nil }
        guard token.allSatisfy({ $0 >= "0" && $0 <= "9" }) else { return nil }
        if token.count > 1 && token.first == "0" { return nil }
        return Int(token)
    }

    /// Loads the latest saved edits for the given resultID and validates them against recognition result.
    ///
    /// If no edits file exists, returns `revision 0` with empty overrides without writing to disk.
    public func loadEdits(resultID: String) throws -> TranscriptEdits {
        acquireOperationGate(.load)
        defer { operationGate.unlock() }
        return try loadEditsGated(resultID: resultID)
    }

    private func loadEditsGated(resultID: String) throws -> TranscriptEdits {
        guard !resultID.isEmpty,
              !resultID.contains("/"),
              !resultID.contains("\\"),
              !resultID.contains("\0"),
              resultID != ".",
              resultID != ".." else {
            throw TranscriptEditsError.resultNotFound(resultID)
        }

        let (resultFile, _) = try verifyContainedPath(
            components: ["raw", "transcripts", resultID, "result.json"],
            allowFinalAbsence: false
        )

        let document: TranscriptDocument
        do {
            document = try TranscriptDocument.load(from: resultFile, recordingDirectory: recordingDirectory)
        } catch {
            throw TranscriptEditsError.resultNotFound(resultID)
        }
        guard document.resultID == resultID else {
            throw TranscriptEditsError.resultNotFound(resultID)
        }
        let validTurnIDs = Set(document.turns.map(\.id))

        let (editsFile, exists) = try verifyContainedPath(
            components: ["raw", "transcripts", resultID, "edits.json"],
            allowFinalAbsence: true
        )

        guard exists else {
            let initial = TranscriptEdits.initial(resultID: resultID)
            lock.withLock {
                if let existing = snapshots[resultID], existing.exists {
                    undoHistory[resultID] = []
                }
                snapshots[resultID] = LoadedSnapshot(edits: initial, data: nil, exists: false)
            }
            return initial
        }

        let data: Data
        do {
            data = try Data(contentsOf: editsFile)
        } catch {
            throw TranscriptEditsError.malformed("Cannot read edits.json: \(error.localizedDescription)")
        }

        guard let rawSchemaToken = try Self.scanTopLevelToken(data: data, targetKey: "schemaVersion"),
              let schemaVersion = Self.parseExactNonnegativeInteger(token: rawSchemaToken) else {
            throw TranscriptEditsError.malformed("schemaVersion must be an integer")
        }
        guard schemaVersion == 1 else {
            throw TranscriptEditsError.unsupportedVersion(schemaVersion)
        }

        guard let rawRevToken = try Self.scanTopLevelToken(data: data, targetKey: "revision"),
              let revision = Self.parseExactNonnegativeInteger(token: rawRevToken) else {
            throw TranscriptEditsError.malformed("revision must be a nonnegative integer")
        }

        let rawJson: Any
        do {
            rawJson = try JSONSerialization.jsonObject(with: data)
        } catch {
            throw TranscriptEditsError.malformed("Invalid JSON: \(error.localizedDescription)")
        }
        guard let dict = rawJson as? [String: Any] else {
            throw TranscriptEditsError.malformed("Root must be a JSON object")
        }

        guard let fileResultID = dict["resultID"] as? String else {
            throw TranscriptEditsError.malformed("resultID must be a string")
        }
        guard fileResultID == resultID else {
            throw TranscriptEditsError.malformed("resultID mismatch: expected \(resultID), got \(fileResultID)")
        }

        guard !(dict["overrides"] is NSNull) else {
            throw TranscriptEditsError.malformed("overrides must not be null")
        }
        guard let overridesDict = dict["overrides"] as? [String: Any] else {
            throw TranscriptEditsError.malformed("overrides must be an object")
        }

        var parsedOverrides: [String: TranscriptTurnOverride] = [:]
        for (turnKey, overrideVal) in overridesDict {
            guard validTurnIDs.contains(turnKey) else {
                throw TranscriptEditsError.invalidReference("Unknown turnID in overrides: \(turnKey)")
            }
            guard !(overrideVal is NSNull) else {
                throw TranscriptEditsError.malformed("turn override must not be null")
            }
            guard let turnDict = overrideVal as? [String: Any] else {
                throw TranscriptEditsError.malformed("turn override must be an object")
            }

            var text: String? = nil
            if let rawText = turnDict["text"] {
                guard !(rawText is NSNull) else {
                    throw TranscriptEditsError.malformed("text must not be null")
                }
                guard let strText = rawText as? String else {
                    throw TranscriptEditsError.malformed("text must be a string")
                }
                text = strText
            }

            var displayName: String? = nil
            if let rawName = turnDict["displayName"] {
                guard !(rawName is NSNull) else {
                    throw TranscriptEditsError.malformed("displayName must not be null")
                }
                guard let strName = rawName as? String else {
                    throw TranscriptEditsError.malformed("displayName must be a string")
                }
                guard !strName.isEmpty else {
                    throw TranscriptEditsError.malformed("displayName must not be empty")
                }
                displayName = strName
            }

            parsedOverrides[turnKey] = TranscriptTurnOverride(text: text, displayName: displayName)
        }

        let edits = TranscriptEdits(
            schemaVersion: schemaVersion,
            resultID: resultID,
            revision: revision,
            overrides: parsedOverrides
        )
        lock.withLock {
            if let existing = snapshots[resultID] {
                if !existing.exists || existing.data != data {
                    undoHistory[resultID] = []
                }
            }
            snapshots[resultID] = LoadedSnapshot(edits: edits, data: data, exists: true)
        }
        return edits
    }

    private func createStagingFile(in dir: URL) throws -> (url: URL, fd: Int32) {
        for _ in 0..<10 {
            let tempURL = dir.appendingPathComponent("edits.json.tmp.\(UUID().uuidString)")
            #if canImport(Darwin)
            let fd = open(tempURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
            if fd >= 0 {
                return (tempURL, fd)
            }
            if errno == EEXIST {
                continue
            }
            throw TranscriptEditsError.malformed("Cannot create staging file: errno \(errno)")
            #else
            throw TranscriptEditsError.notImplemented
            #endif
        }
        throw TranscriptEditsError.malformed("Failed to create unique staging file after 10 attempts")
    }

    private func writeFully(fd: Int32, data: Data) throws {
        if let hook = stagingWriteHook {
            try hook(fd, data)
        }
        #if canImport(Darwin)
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            var written = 0
            let total = buffer.count
            while written < total {
                let toWrite = total - written
                let res = write(fd, baseAddress.advanced(by: written), toWrite)
                if res < 0 {
                    let err = errno
                    if err == EINTR { continue }
                    throw TranscriptEditsError.malformed("Write to staging failed: errno \(err)")
                }
                written += res
            }
        }
        #endif
    }

    private func saveOverridesInternal(
        resultID: String,
        isUndo: Bool = false,
        mutating: (inout [String: TranscriptTurnOverride]) throws -> Void
    ) throws -> TranscriptEdits {
        acquireOperationGate(.save)
        defer { operationGate.unlock() }
        return try saveOverridesInternalGated(resultID: resultID, isUndo: isUndo, mutating: mutating)
    }

    /// Executes an atomic read-modify-write mutation on the current loaded snapshot within the operation gate.
    /// Does not reload from disk if a snapshot already exists, enforcing CAS conflict detection against external changes.
    internal func mutateOverrides(
        resultID: String,
        mutating: (inout [String: TranscriptTurnOverride]) throws -> Void
    ) throws -> TranscriptEdits {
        try saveOverridesInternal(resultID: resultID, mutating: mutating)
    }

    private func saveOverridesInternalGated(
        resultID: String,
        isUndo: Bool = false,
        mutating: (inout [String: TranscriptTurnOverride]) throws -> Void
    ) throws -> TranscriptEdits {
        try acquireWriteLock()

        guard !resultID.isEmpty,
              !resultID.contains("/"),
              !resultID.contains("\\"),
              !resultID.contains("\0"),
              resultID != ".",
              resultID != ".." else {
            throw TranscriptEditsError.resultNotFound(resultID)
        }

        let (resultFile, _) = try verifyContainedPath(
            components: ["raw", "transcripts", resultID, "result.json"],
            allowFinalAbsence: false
        )

        let document: TranscriptDocument
        do {
            document = try TranscriptDocument.load(from: resultFile, recordingDirectory: recordingDirectory)
        } catch {
            throw TranscriptEditsError.resultNotFound(resultID)
        }
        guard document.resultID == resultID else {
            throw TranscriptEditsError.resultNotFound(resultID)
        }
        let validTurnIDs = Set(document.turns.map(\.id))

        let (editsFile, _) = try verifyContainedPath(
            components: ["raw", "transcripts", resultID, "edits.json"],
            allowFinalAbsence: true
        )

        let snapshot: LoadedSnapshot
        if let existing = loadedSnapshot(for: resultID) {
            snapshot = existing
        } else {
            _ = try loadEditsGated(resultID: resultID)
            guard let reloaded = loadedSnapshot(for: resultID) else {
                throw TranscriptEditsError.malformed("Cannot load initial snapshot")
            }
            snapshot = reloaded
        }

        #if canImport(Darwin)
        var stCurrent = stat()
        let currentLstat = lstat(editsFile.path, &stCurrent)
        if snapshot.exists {
            guard currentLstat == 0 else {
                throw TranscriptEditsError.conflict("edits.json was deleted externally")
            }
            let currentBytes = try Data(contentsOf: editsFile)
            guard currentBytes == snapshot.data else {
                throw TranscriptEditsError.conflict("edits.json was modified externally")
            }
        } else {
            guard currentLstat != 0 else {
                throw TranscriptEditsError.conflict("edits.json was created externally")
            }
        }
        #endif

        guard snapshot.edits.revision < Int.max else {
            throw TranscriptEditsError.malformed("Revision overflow")
        }
        let nextRevision = snapshot.edits.revision + 1

        var newOverrides = snapshot.edits.overrides
        try mutating(&newOverrides)

        for (turnID, overrideVal) in newOverrides {
            guard validTurnIDs.contains(turnID) else {
                throw TranscriptEditsError.invalidReference("Unknown turnID in overrides: \(turnID)")
            }
            if let name = overrideVal.displayName {
                guard !name.isEmpty else {
                    throw TranscriptEditsError.malformed("displayName must not be empty")
                }
            }
        }

        let words = Dictionary(uniqueKeysWithValues: document.words.map { ($0.id, $0.text) })
        let speakers = Dictionary(uniqueKeysWithValues: document.speakers.map { ($0.id, $0.displayNumber) })
        for turn in document.turns {
            guard var value = newOverrides[turn.id] else { continue }
            let prior = snapshot.edits.overrides[turn.id]
            if prior?.text == nil, value.text?.utf8.elementsEqual(turn.wordIDs.compactMap({ words[$0] }).joined(separator: " ").utf8) == true { value.text = nil }
            if prior?.displayName == nil, value.displayName == "Speaker \(speakers[turn.speakerID] ?? 1)" { value.displayName = nil }
            if value.text == nil, value.displayName == nil, prior == nil { newOverrides.removeValue(forKey: turn.id) }
            else { newOverrides[turn.id] = value }
        }
        let unchanged = newOverrides.count == snapshot.edits.overrides.count && newOverrides.allSatisfy { id, value in
            guard let prior = snapshot.edits.overrides[id] else { return false }
            let sameText: Bool
            switch (value.text, prior.text) {
            case (.none, .none): sameText = true
            case let (.some(lhs), .some(rhs)): sameText = lhs.utf8.elementsEqual(rhs.utf8)
            default: sameText = false
            }
            return sameText && value.displayName == prior.displayName
        }
        if unchanged { return snapshot.edits }

        let newEdits = TranscriptEdits(
            schemaVersion: 1,
            resultID: resultID,
            revision: nextRevision,
            overrides: newOverrides
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encodedData = try encoder.encode(newEdits)

        let (tempURL, tempFD) = try createStagingFile(in: editsFile.deletingLastPathComponent())
        var openFD: Int32? = tempFD
        var renamed = false
        defer {
            if let fd = openFD {
                close(fd)
            }
            if !renamed {
                unlink(tempURL.path)
            }
        }

        try writeFully(fd: tempFD, data: encodedData)
        close(tempFD)
        openFD = nil

        if let hook = atomicReplaceHook {
            try hook(tempURL, editsFile)
        }

        #if canImport(Darwin)
        var stFinal = stat()
        let finalLstat = lstat(editsFile.path, &stFinal)
        if snapshot.exists {
            guard finalLstat == 0 else {
                throw TranscriptEditsError.conflict("edits.json was deleted externally")
            }
            let currentBytes = try Data(contentsOf: editsFile)
            guard currentBytes == snapshot.data else {
                throw TranscriptEditsError.conflict("edits.json was modified externally")
            }
        } else {
            guard finalLstat != 0 else {
                throw TranscriptEditsError.conflict("edits.json was created externally")
            }
        }

        guard rename(tempURL.path, editsFile.path) == 0 else {
            throw TranscriptEditsError.malformed("rename failed with errno \(errno)")
        }
        renamed = true
        #else
        _ = try FileManager.default.replaceItemAt(editsFile, withItemAt: tempURL)
        renamed = true
        #endif

        lock.withLock {
            snapshots[resultID] = LoadedSnapshot(edits: newEdits, data: encodedData, exists: true)
            if !isUndo {
                undoHistory[resultID, default: []].append(snapshot.edits.overrides)
            } else {
                if var history = undoHistory[resultID], !history.isEmpty {
                    history.removeLast()
                    undoHistory[resultID] = history
                }
            }
        }
        return newEdits
    }

    /// Saves text and/or displayName overrides for a specific turnID.
    public func saveTurnOverride(
        resultID: String,
        turnID: String,
        text: String?,
        displayName: String?
    ) throws -> TranscriptEdits {
        if let text, text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            throw TranscriptEditsError.malformed("text must not be empty or blank")
        }
        return try saveOverridesInternal(resultID: resultID) { overrides in
            guard !turnID.isEmpty else {
                throw TranscriptEditsError.invalidReference("turnID must not be empty")
            }
            if let name = displayName {
                guard !name.isEmpty else {
                    throw TranscriptEditsError.malformed("displayName must not be empty")
                }
            }
            var existing = overrides[turnID] ?? TranscriptTurnOverride()
            if let text { existing.text = text }
            if let displayName { existing.displayName = displayName }
            if existing.text != nil || existing.displayName != nil { overrides[turnID] = existing }
        }
    }

    /// Saves batch overrides for the given resultID.
    public func saveEdits(
        resultID: String,
        overrides: [String: TranscriptTurnOverride]
    ) throws -> TranscriptEdits {
        try saveOverridesInternal(resultID: resultID) { currentOverrides in
            for (turnKey, overrideVal) in overrides {
                guard !turnKey.isEmpty else {
                    throw TranscriptEditsError.invalidReference("turnID must not be empty")
                }
                if let name = overrideVal.displayName {
                    guard !name.isEmpty else {
                        throw TranscriptEditsError.malformed("displayName must not be empty")
                    }
                }
                currentOverrides[turnKey] = overrideVal
            }
        }
    }

    /// Whether undo is available for the given resultID in the current repository session.
    public func canUndo(resultID: String) -> Bool {
        lock.withLock {
            guard let history = undoHistory[resultID] else { return false }
            return !history.isEmpty
        }
    }

    /// Reverts the last save operation for the given resultID, saving the reverted state as a new revision.
    public func undo(resultID: String) throws -> TranscriptEdits {
        acquireOperationGate(.undo)
        defer { operationGate.unlock() }

        guard let targetPriorOverrides = lock.withLock({ undoHistory[resultID]?.last }) else {
            throw TranscriptEditsError.noUndoHistory("No undo history available for \(resultID)")
        }

        return try saveOverridesInternalGated(resultID: resultID, isUndo: true) { overrides in
            overrides = targetPriorOverrides
        }
    }
}

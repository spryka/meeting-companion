import Foundation
import Darwin

public enum TranscriptExportError: LocalizedError, Equatable, Sendable {
    case resultMismatch(expected: String, got: String)
    case protectedDestination(String)
    case destinationExists(String)
    case writeFailed(String)

    public var errorDescription: String? {
        switch self {
        case .resultMismatch(let expected, let got):
            return "Несоответствие версии результата: ожидалось \(expected), получено \(got)"
        case .protectedDestination(let detail):
            return "Небезопасный путь назначения: файл защищён от перезаписи (\(detail))"
        case .destinationExists(let path):
            return "Файл назначения уже существует: \(path)"
        case .writeFailed(let detail):
            return "Ошибка записи экспорта: \(detail)"
        }
    }
}

public struct TranscriptExportFormatter: Sendable {
    public init() {}

    public static func formatTimestamp(seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "00:00:00" }
        let total = floor(seconds)
        let hours = floor(total / 3600.0)
        let remainder = total.truncatingRemainder(dividingBy: 3600.0)
        let mins = floor(remainder / 60.0)
        let secs = remainder.truncatingRemainder(dividingBy: 60.0)

        let hoursStr: String
        if hours < 100 {
            hoursStr = String(format: "%02.0f", hours)
        } else {
            hoursStr = String(format: "%.0f", hours)
        }
        let minsStr = String(format: "%02.0f", mins)
        let secsStr = String(format: "%02.0f", secs)
        return "\(hoursStr):\(minsStr):\(secsStr)"
    }

    public static func localizedWarningText(for warning: TranscriptDocument.Warning) -> String {
        switch warning.code {
        case "diarization_voice_limit":
            return "Достигнут предел распознавания 8 голосов."
        case "aec_failed":
            return "Эхоподавление не выполнено; распознаётся исходный микрофон."
        case "aec_warning":
            return "Эхоподавление завершилось с предупреждением."
        case "correction_failed":
            return "Коррекция терминов не выполнена; сохранён исходный текст."
        case "playback_mix_failed":
            return "Подготовка совместного аудио не удалась; доступен только текстовый режим."
        case "diarization_failed":
            return "Разделение голосов не выполнено."
        case "capture_warning":
            return "Предупреждение захвата аудио."
        case "recognition_warning":
            return "Предупреждение распознавания речи."
        case "context_unavailable":
            return "Не удалось прочитать контекст встречи."
        case "recognition_voice_limit_recovery_failed":
            return "Восстановление после превышения лимита голосов не выполнено."
        default:
            return "Предупреждение обработки записи."
        }
    }

    public static func validate(edits: TranscriptEdits, against document: TranscriptDocument) throws {
        guard document.resultID == edits.resultID else {
            throw TranscriptExportError.resultMismatch(expected: document.resultID, got: edits.resultID)
        }
        guard edits.schemaVersion == 1 else {
            throw TranscriptExportError.writeFailed("Unsupported edits schemaVersion: \(edits.schemaVersion)")
        }
        guard edits.revision >= 0 else {
            throw TranscriptExportError.writeFailed("Negative edits revision: \(edits.revision)")
        }
        let validTurnIDs = Set(document.turns.map(\.id))
        for (turnID, override) in edits.overrides {
            guard validTurnIDs.contains(turnID) else {
                throw TranscriptExportError.writeFailed("Unknown turn ID in overrides: \(turnID)")
            }
            if let name = override.displayName {
                guard !name.isEmpty, !name.allSatisfy(\.isWhitespace) else {
                    throw TranscriptExportError.writeFailed("Empty or blank displayName in overrides for turn \(turnID)")
                }
            }
        }
    }

    /// Formats the saved transcript document and its saved edits into a readable text export.
    public func format(
        document: TranscriptDocument,
        edits: TranscriptEdits,
        recordingDirectory: URL? = nil
    ) throws -> String {
        try Self.validate(edits: edits, against: document)

        var sections: [String] = []

        // 1. Header (Context)
        var headerLines: [String] = []
        if let context = document.context {
            if let title = context.title, !title.isEmpty {
                headerLines.append(title)
            }
            if let startAt = context.startAt, !startAt.isEmpty {
                headerLines.append("Дата и время: \(startAt)")
            }
            if let tz = context.timeZone, !tz.isEmpty {
                headerLines.append("Часовой пояс: \(tz)")
            }
            if let agenda = context.agenda, !agenda.isEmpty {
                headerLines.append("Повестка: \(agenda)")
            }
            if let attendees = context.attendees, !attendees.isEmpty {
                let nonEmptyAttendees = attendees.filter { !$0.isEmpty }
                if !nonEmptyAttendees.isEmpty {
                    headerLines.append("Приглашены: \(nonEmptyAttendees.joined(separator: ", "))")
                }
            }
        }

        if !headerLines.isEmpty {
            sections.append(headerLines.joined(separator: "\n"))
        }

        // 2. Warnings
        let warnings = document.presentationWarnings
        if !warnings.isEmpty {
            var warningLines: [String] = ["Предупреждения:"]
            for warning in warnings {
                let track = warning.sourceID != nil ? "[\(TranscriptDocument.localizedSourceLabel(for: warning.sourceID!))] " : ""
                let text = Self.localizedWarningText(for: warning)
                warningLines.append("\(track)\(text)")
            }
            sections.append(warningLines.joined(separator: "\n"))
        }

        // 3. Turns
        let presentation = TranscriptTextPresentation(document: document, overrides: edits.overrides)
        let speakers = Dictionary(uniqueKeysWithValues: document.speakers.map { ($0.id, $0) })

        var turnBlocks: [String] = []
        for turn in document.turns {
            let timestamp = Self.formatTimestamp(seconds: turn.start)
            let speaker = speakers[turn.speakerID]
            let displayNumber = speaker?.displayNumber ?? 1

            let speakerName: String
            if let overrideName = edits.overrides[turn.id]?.displayName,
               !overrideName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                speakerName = overrideName
            } else {
                speakerName = "Speaker \(displayNumber)"
            }

            let turnText = presentation.readingText[turn.id] ?? ""

            turnBlocks.append("[\(timestamp)] \(speakerName):\n\(turnText)")
        }

        if !turnBlocks.isEmpty {
            sections.append(turnBlocks.joined(separator: "\n\n"))
        }

        return sections.joined(separator: "\n\n") + "\n"
    }
}

public struct TranscriptExportWriter: Sendable {
    public typealias PrePublishHook = @Sendable (_ stagingURL: URL, _ destinationURL: URL) throws -> Void

    public let recordingDirectory: URL
    public let prePublishHook: PrePublishHook?

    public init(recordingDirectory: URL, prePublishHook: PrePublishHook? = nil) {
        self.recordingDirectory = recordingDirectory
        self.prePublishHook = prePublishHook
    }

    private func isProtected(destinationURL: URL) throws -> Bool {
        let canonicalRecordingDir = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL

        // Canonicalize destination: resolve existing parent first, then append filename
        let destStandard = destinationURL.standardizedFileURL
        let destParent = destStandard.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
        let canonicalDest = destParent.appendingPathComponent(destStandard.lastPathComponent).standardizedFileURL

        // 1. Any destination within recording directory tree is protected
        let recComponents = canonicalRecordingDir.pathComponents
        let destComponents = canonicalDest.pathComponents
        if destComponents.count >= recComponents.count && Array(destComponents.prefix(recComponents.count)) == recComponents {
            return true
        }

        // Also check if destination directly exists and resolves into recording
        if FileManager.default.fileExists(atPath: destStandard.path) {
            let realExisting = destStandard.resolvingSymlinksInPath().standardizedFileURL
            let realExistingComponents = realExisting.pathComponents
            if realExistingComponents.count >= recComponents.count && Array(realExistingComponents.prefix(recComponents.count)) == recComponents {
                return true
            }
        }

        // 2. Device and Inode check if destination exists (hardlink protection)
        // Compare RESOLVED REFERENT device and inode against all recording artifacts!
        #if canImport(Darwin)
        var destStat = stat()
        // stat follows the final symlink. Never substitute the symlink inode when
        // its referent is inaccessible: that cannot establish alias safety.
        let hasStat = stat(canonicalDest.path, &destStat) == 0
        if !hasStat {
            let err = errno
            guard err == ENOENT else {
                throw TranscriptExportError.protectedDestination("Cannot stat destination referent: errno \(err)")
            }
        }
        if hasStat {
            var caughtError: Error?
            let enumerator = FileManager.default.enumerator(
                at: canonicalRecordingDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [],
                errorHandler: { url, error in
                    caughtError = error
                    return false
                }
            )
            while let fileURL = enumerator?.nextObject() as? URL {
                if let err = caughtError {
                    throw TranscriptExportError.protectedDestination("Inaccessible recording subtree: \(err.localizedDescription)")
                }
                var fileStat = stat()
                if lstat(fileURL.path, &fileStat) != 0 {
                    let err = errno
                    if err != ENOENT {
                        throw TranscriptExportError.protectedDestination("Cannot stat recording file \(fileURL.path): errno \(err)")
                    }
                    continue
                }
                if destStat.st_dev == fileStat.st_dev && destStat.st_ino == fileStat.st_ino {
                    return true
                }
            }
            if let err = caughtError {
                throw TranscriptExportError.protectedDestination("Inaccessible recording subtree: \(err.localizedDescription)")
            }
        }
        #endif

        return false
    }

    /// Exports the formatted transcript to destination URL with atomic staging and destination protection.
    public func export(
        document: TranscriptDocument,
        edits: TranscriptEdits,
        to destinationURL: URL,
        allowOverwrite: Bool = false
    ) throws {
        try TranscriptExportFormatter.validate(edits: edits, against: document)

        if try isProtected(destinationURL: destinationURL) {
            throw TranscriptExportError.protectedDestination("Destination resolves to protected recording file: \(destinationURL.path)")
        }

        let standardDest = destinationURL.standardizedFileURL
        let destExists = FileManager.default.fileExists(atPath: standardDest.path)
        if destExists && !allowOverwrite {
            throw TranscriptExportError.destinationExists(standardDest.path)
        }

        let formatter = TranscriptExportFormatter()
        let content = try formatter.format(document: document, edits: edits, recordingDirectory: recordingDirectory)
        guard let data = content.data(using: .utf8) else {
            throw TranscriptExportError.writeFailed("Failed to encode UTF-8 text")
        }

        let parentDir = standardDest.deletingLastPathComponent()
        let tempURL = parentDir.appendingPathComponent(".export.tmp.\(UUID().uuidString)")

        #if canImport(Darwin)
        let fd = open(tempURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else {
            throw TranscriptExportError.writeFailed("Failed to create temporary staging file: errno \(errno)")
        }

        var openFD: Int32? = fd
        var renamed = false
        defer {
            if let fd = openFD {
                close(fd)
            }
            if !renamed {
                unlink(tempURL.path)
            }
        }

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
                    throw TranscriptExportError.writeFailed("Write to staging failed: errno \(err)")
                }
                written += res
            }
        }

        close(fd)
        openFD = nil

        if let hook = prePublishHook {
            try hook(tempURL, standardDest)
        }

        if allowOverwrite {
            guard rename(tempURL.path, standardDest.path) == 0 else {
                throw TranscriptExportError.writeFailed("Rename failed: errno \(errno)")
            }
            renamed = true
        } else {
            let res = renamex_np(tempURL.path, standardDest.path, UInt32(RENAME_EXCL))
            if res != 0 {
                let err = errno
                if err == EEXIST {
                    throw TranscriptExportError.destinationExists(standardDest.path)
                }
                throw TranscriptExportError.writeFailed("Atomic renamex_np failed: errno \(err)")
            }
            renamed = true
        }
        #else
        try data.write(to: tempURL)
        _ = try FileManager.default.replaceItemAt(standardDest, withItemAt: tempURL)
        #endif
    }
}

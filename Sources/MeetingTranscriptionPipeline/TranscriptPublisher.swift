import Foundation
import MeetingCompanionCore
import Darwin

public enum TranscriptPublishError: LocalizedError, Sendable {
    case invalidRecordingDirectory(String)
    case invalidResultID(String)
    case destinationExists(String)
    case publicationFailed(String)
    case validationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .invalidRecordingDirectory(let path):
            return "Некорректная директория записи или экранирование через symlink: \(path)"
        case .invalidResultID(let id):
            return "Некорректный идентификатор версии (resultID): \(id)"
        case .destinationExists(let id):
            return "Версия расшифровки уже существует: \(id)"
        case .publicationFailed(let detail):
            return "Сбой атомарной публикации версии: \(detail)"
        case .validationFailed(let detail):
            return "Сбой валидации документа перед публикацией: \(detail)"
        }
    }
}

public struct TranscriptPublisher: Sendable {
    public let recordingDirectory: URL

    public init(recordingDirectory: URL) {
        self.recordingDirectory = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL
    }

    /// Validates directory containment ensuring neither raw nor transcripts escapes via symlinks.
    /// Checks existing raw and transcripts path prefixes BEFORE any writes.
    @discardableResult
    public static func validateContainment(of recordingDirectory: URL) throws -> URL {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: recordingDirectory.path, isDirectory: &isDir),
              isDir.boolValue else {
            throw TranscriptPublishError.invalidRecordingDirectory(recordingDirectory.path)
        }

        let standardRoot = recordingDirectory.resolvingSymlinksInPath().standardizedFileURL
        let rawDir = recordingDirectory.appendingPathComponent("raw")
        if FileManager.default.fileExists(atPath: rawDir.path) {
            let standardRaw = rawDir.resolvingSymlinksInPath().standardizedFileURL
            let rawComponents = standardRaw.pathComponents
            let rootComponents = standardRoot.pathComponents
            guard rawComponents.count > rootComponents.count,
                  rawComponents.starts(with: rootComponents) else {
                throw TranscriptPublishError.invalidRecordingDirectory("Каталог raw выходит за пределы recordingDirectory: \(standardRaw.path)")
            }
        }

        let transcriptsDir = rawDir.appendingPathComponent("transcripts")
        if FileManager.default.fileExists(atPath: transcriptsDir.path) {
            let standardTranscripts = transcriptsDir.resolvingSymlinksInPath().standardizedFileURL
            let transcriptsComponents = standardTranscripts.pathComponents
            let rootComponents = standardRoot.pathComponents
            guard transcriptsComponents.count > rootComponents.count,
                  transcriptsComponents.starts(with: rootComponents) else {
                throw TranscriptPublishError.invalidRecordingDirectory("Каталог transcripts выходит за пределы recordingDirectory: \(standardTranscripts.path)")
            }
        }

        try FileManager.default.createDirectory(at: transcriptsDir, withIntermediateDirectories: true)

        let standardTranscripts = transcriptsDir.resolvingSymlinksInPath().standardizedFileURL
        let rootComponents = standardRoot.pathComponents
        let transcriptsComponents = standardTranscripts.pathComponents

        guard transcriptsComponents.count > rootComponents.count,
              transcriptsComponents.starts(with: rootComponents) else {
            throw TranscriptPublishError.invalidRecordingDirectory("Каталог transcripts выходит за пределы recordingDirectory: \(standardTranscripts.path)")
        }

        return transcriptsDir
    }

    /// Validates directory containment for this publisher instance.
    @discardableResult
    public func validateDirectoryContainment() throws -> URL {
        try Self.validateContainment(of: recordingDirectory)
    }

    /// Atomically publishes a transcript document and companion files
    /// into raw/transcripts/<resultID>/ without replacing existing versions.
    @discardableResult
    public func publish(
        document: TranscriptDocument,
        audioMixURL: URL? = nil,
        audioMixData: Data? = nil,
        aecAudioURL: URL? = nil,
        correctionJournalData: Data? = nil,
        recordingStem: String? = nil,
        hostAudioRelPath: String? = nil,
        remoteAudioRelPath: String? = nil,
        checkCancel: () throws -> Void = {},
        beforeCommit: ((URL) throws -> Void)? = nil,
        onWarning: (String) -> Void = { _ in }
    ) throws -> URL {
        try checkCancel()
        let resultID = document.resultID
        guard !resultID.isEmpty,
              resultID != ".",
              resultID != "..",
              !resultID.contains("/"),
              !resultID.contains("\\"),
              !resultID.contains("\0") else {
            throw TranscriptPublishError.invalidResultID(resultID)
        }

        let transcriptsDir = try validateDirectoryContainment()
        let targetDir = transcriptsDir.appendingPathComponent(resultID)

        if FileManager.default.fileExists(atPath: targetDir.path) {
            throw TranscriptPublishError.destinationExists(resultID)
        }

        let stagingDirName = ".staging-\(resultID)-\(UUID().uuidString)"
        let stagingDir = transcriptsDir.appendingPathComponent(stagingDirName)
        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        var committed = false
        defer {
            if !committed {
                try? FileManager.default.removeItem(at: stagingDir)
            }
        }

        let stagingResultJSON = stagingDir.appendingPathComponent("result.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encodedData = try encoder.encode(document)
        try encodedData.write(to: stagingResultJSON, options: .atomic)

        // Publish audio mix
        let stagingMixURL = stagingDir.appendingPathComponent("mix.m4a")
        if let mixURL = audioMixURL {
            if FileManager.default.fileExists(atPath: mixURL.path) {
                // Link or copy without reading into memory Data
                if link(mixURL.path, stagingMixURL.path) != 0 {
                    try FileManager.default.copyItem(at: mixURL, to: stagingMixURL)
                }
            }
        } else if let mixData = audioMixData {
            try mixData.write(to: stagingMixURL, options: .atomic)
        }

        // Publish AEC processed host audio if applied
        if let aecURL = aecAudioURL, FileManager.default.fileExists(atPath: aecURL.path) {
            let stagingAECURL = stagingDir.appendingPathComponent("host_aec.wav")
            if link(aecURL.path, stagingAECURL.path) != 0 {
                try FileManager.default.copyItem(at: aecURL, to: stagingAECURL)
            }
        }

        // Publish correction journal if present
        if let journalData = correctionJournalData {
            let journalURL = stagingDir.appendingPathComponent("correction_journal.json")
            try journalData.write(to: journalURL, options: .atomic)
        }

        // Validate that playback ready has an existing and readable mix file
        if document.playback.status == .ready {
            guard FileManager.default.isReadableFile(atPath: stagingMixURL.path) else {
                throw TranscriptPublishError.validationFailed("playback.status == .ready требует наличия читаемого mix.m4a")
            }
        }

        // Validate via actual Core loading semantics
        do {
            _ = try TranscriptDocument.load(from: stagingResultJSON, recordingDirectory: recordingDirectory)
        } catch {
            throw TranscriptPublishError.validationFailed(error.localizedDescription)
        }

        let text = renderText(document: document, stem: recordingStem ?? recordingDirectory.lastPathComponent,
            hostAudioRelPath: hostAudioRelPath ?? "raw/host_record.wav",
            remoteAudioRelPath: remoteAudioRelPath ?? "raw/remote_record.wav")
        try text.write(to: stagingDir.appendingPathComponent("transcript.txt"), atomically: true, encoding: .utf8)
        try beforeCommit?(stagingDir)
        try checkCancel()

        // The directory rename is the only publication commit.
        // Perform Darwin atomic no-replace rename
        let ret = Darwin.renamex_np(stagingDir.path, targetDir.path, UInt32(RENAME_EXCL))
        guard ret == 0 else {
            let err = errno
            if err == EEXIST {
                throw TranscriptPublishError.destinationExists(resultID)
            }
            throw TranscriptPublishError.publicationFailed(String(cString: strerror(err)))
        }

        committed = true

        if let stem = recordingStem {
            do {
                let cache = recordingDirectory.appendingPathComponent("\(stem).sources.transcript.txt")
                let resolved = cache.resolvingSymlinksInPath().standardizedFileURL
                guard resolved.deletingLastPathComponent() == recordingDirectory else {
                    throw TranscriptPublishError.invalidRecordingDirectory(cache.path)
                }
                try text.write(to: cache, atomically: true, encoding: .utf8)
            } catch {
                onWarning("Результат сохранён; не удалось обновить текстовый экспорт: " + error.localizedDescription)
            }
        }

        return targetDir.appendingPathComponent("result.json")
    }

    /// Formats and publishes .sources.transcript.txt companion files for editor and history.
    private func renderText(
        document: TranscriptDocument,
        stem: String,
        hostAudioRelPath: String,
        remoteAudioRelPath: String
    ) -> String {
        var lines: [String] = [
            "Transcript: \(stem) — separate sources",
            "Host audio: \(hostAudioRelPath)",
            "Remote audio: \(remoteAudioRelPath)"
        ]

        if document.aec.outcome == .applied {
            lines.append("Microphone processing: WebRTC AEC3 (beta); raw/transcripts/\(document.resultID)/host_aec.wav")
        }

        for warning in document.warnings {
            lines.append("Warning: \(warning.message)")
        }

        let speakerMap = Dictionary(uniqueKeysWithValues: document.speakers.map { ($0.id, $0.displayNumber) })
        let wordsByID = Dictionary(uniqueKeysWithValues: document.words.map { ($0.id, $0.text) })
        for turn in document.turns {
            let num = speakerMap[turn.speakerID] ?? 1
            let totalSeconds = Int(turn.start)
            let hours = totalSeconds / 3600
            let minutes = (totalSeconds % 3600) / 60
            let seconds = totalSeconds % 60
            let timeStr = String(format: "[%02d:%02d:%02d]", hours, minutes, seconds)
            let turnText = turn.wordIDs.compactMap { wordsByID[$0] }.joined(separator: " ")
            lines.append("\(timeStr) Speaker \(num): \(turnText)")
        }

        return lines.joined(separator: "\n") + "\n"
    }
}

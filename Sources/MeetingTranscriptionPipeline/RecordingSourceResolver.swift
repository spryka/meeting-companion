import Foundation
import MeetingCompanionCore

public struct RecordingSources: Sendable {
    public let recordingDirectory: URL
    public let stem: String
    public let hostWAV: URL
    public let remoteWAV: URL
    public let hostRelPath: String
    public let remoteRelPath: String
    public let contextWarnings: [String]

    public init(
        recordingDirectory: URL,
        stem: String,
        hostWAV: URL,
        remoteWAV: URL,
        hostRelPath: String,
        remoteRelPath: String,
        contextWarnings: [String] = []
    ) {
        self.recordingDirectory = recordingDirectory
        self.stem = stem
        self.hostWAV = hostWAV
        self.remoteWAV = remoteWAV
        self.hostRelPath = hostRelPath
        self.remoteRelPath = remoteRelPath
        self.contextWarnings = contextWarnings
    }
}

public enum RecordingResolverError: LocalizedError, Sendable {
    case missingRecordingFile(String)
    case missingSources(stem: String, expectedPaths: [String])
    case inputAliasesSource(String)

    public var errorDescription: String? {
        switch self {
        case .missingRecordingFile(let path):
            return "Файл или путь записи не найден: \(path)"
        case .missingSources(let stem, let expected):
            return "Не найдены исходные аудиодорожки для «\(stem)». Ожидались: \(expected.joined(separator: ", "))"
        case .inputAliasesSource(let path):
            return "Выходной путь совпадает с исходным аудио: \(path)"
        }
    }
}

public struct RecordingSourceResolver: Sendable {
    public init() {}

    /// Deterministically resolves host and remote audio recordings matching the app contract.
    /// Requires a dedicated recording folder and its exact raw source pair.
    /// No recursive globbing or fallback that could transcribe another session.
    public static func resolve(recordingPath: String) throws -> RecordingSources {
        let fileURL = URL(fileURLWithPath: recordingPath)
        let standardURL = fileURL.resolvingSymlinksInPath().standardizedFileURL

        let stem: String
        let recordingDir: URL

        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: standardURL.path, isDirectory: &isDir), isDir.boolValue {
            // Path was passed as a directory directly
            recordingDir = standardURL
            stem = standardURL.lastPathComponent
        } else {
            // Path was passed as a file URL or path without extension
            let recording = RecordingEntry.canonicalURL(fileURL)
            stem = recording.deletingPathExtension().lastPathComponent
            recordingDir = recording.deletingLastPathComponent()
        }

        try RecordingPaths.requireStandardLayout(recordingDir.appendingPathComponent(stem + ".m4a"))
        let rawDir = recordingDir.appendingPathComponent("raw")
        let rawHost = rawDir.appendingPathComponent("\(stem).host_record.wav")
        let rawRemote = rawDir.appendingPathComponent("\(stem).remote_record.wav")

        let finalHost: URL
        let finalRemote: URL
        let hostRel: String
        let remoteRel: String

        let fm = FileManager.default
        let pair = [rawHost, rawRemote]
        let containedPair = pair.allSatisfy { source in
            let resolved = source.resolvingSymlinksInPath().standardizedFileURL
            return resolved.path.hasPrefix(recordingDir.path + "/") &&
                (try? resolved.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true &&
                fm.isReadableFile(atPath: resolved.path)
        }
        guard rawHost.resolvingSymlinksInPath() != rawRemote.resolvingSymlinksInPath(),
              !pair.contains(where: { $0.resolvingSymlinksInPath() == standardURL }) else {
            throw RecordingResolverError.inputAliasesSource(recordingPath)
        }
        if containedPair {
            finalHost = rawHost
            finalRemote = rawRemote
            hostRel = "raw/\(stem).host_record.wav"
            remoteRel = "raw/\(stem).remote_record.wav"
        } else {
            throw RecordingResolverError.missingSources(
                stem: stem,
                expectedPaths: [
                    rawHost.path, rawRemote.path
                ]
            )
        }

        var warnings: [String] = []

        // Parse context warnings if available
        let contextURL = recordingDir.appendingPathComponent("\(stem).context.json")
        if fm.fileExists(atPath: contextURL.path) {
            if let data = try? Data(contentsOf: contextURL),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                // Any specific context checks if needed
                if let participants = json["participants"] as? [[String: Any]], participants.count > 10 {
                    warnings.append("В сохранённом контексте встречи указано участников больше 10: \(participants.count)")
                }
            }
        }

        // Parse capture report warnings if available
        let captureReports = [
            rawDir.appendingPathComponent("\(stem).capture-report.json"),
            recordingDir.appendingPathComponent("\(stem).capture-report.json")
        ]
        for reportURL in captureReports where fm.fileExists(atPath: reportURL.path) {
            if let data = try? Data(contentsOf: reportURL),
               let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                if let dropped = report["droppedBuffers"] as? Int, dropped > 0 {
                    let secs = (report["droppedSourceSeconds"] as? Double) ?? 0
                    warnings.append(String(format: "При захвате пропущено буферов: %d; %.3f с суммарно по дорожкам.", dropped, secs))
                }
                if let exportFail = report["exportFailure"] as? String {
                    warnings.append("Общая запись не собрана: \(exportFail)")
                }
                if let fail = report["failure"] as? String {
                    warnings.append("Сбой захвата: \(fail)")
                }
                if let recoveries = report["microphoneRecoveries"] as? Int, recoveries > 0 {
                    warnings.append("Попыток восстановления микрофона: \(recoveries). В эти моменты возможны пропуски речи.")
                }
                if let missing = report["microphoneMissing"] as? Bool, missing {
                    warnings.append("Во время записи переставали поступать данные микрофона; часть речи могла не сохраниться.")
                }
            }
            break
        }

        return RecordingSources(
            recordingDirectory: recordingDir,
            stem: stem,
            hostWAV: finalHost,
            remoteWAV: finalRemote,
            hostRelPath: hostRel,
            remoteRelPath: remoteRel,
            contextWarnings: warnings
        )
    }
}

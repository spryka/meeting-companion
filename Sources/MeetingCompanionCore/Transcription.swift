import Foundation
import Darwin

public enum Transcription {
    private static let queue = DispatchQueue(label: "MeetingCompanion.transcription")

    public static func run(recording: URL,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let base = recording.deletingPathExtension()
                    var log = base.appendingPathExtension("transcription.log")
                    if FileManager.default.fileExists(atPath: log.path) {
                        log = base.appendingPathExtension("transcription-" + UUID().uuidString + ".log")
                    }
                    let descriptor = Darwin.open(log.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    guard descriptor >= 0 else {
                        throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                    }
                    let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                    defer { try? handle.close() }
                    let process = try makeProcess(arguments: ["--recording", "--offline", recording.path])
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    do {
                        try readProgress(from: pipe.fileHandleForReading, log: handle, onProgress: onProgress)
                    } catch {
                        if process.isRunning { process.terminate() }
                        process.waitUntilExit()
                        throw error
                    }
                    process.waitUntilExit()
                    let transcript = base.appendingPathExtension("sources.transcript.txt")
                    guard process.terminationStatus == 0,
                          FileManager.default.fileExists(atPath: transcript.path) else {
                        throw NSError(domain: "Transcription", code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "Запись сохранена, но транскрибация не завершилась. Подробности: " + log.path])
                    }
                    continuation.resume(returning: transcript)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    public static var scriptsDirectory: URL {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("transcription")
        if let bundled, FileManager.default.fileExists(atPath: bundled.appendingPathComponent("run.sh").path) {
            return bundled
        }
        return URL(fileURLWithPath: "/Applications/Meeting Companion.app/Contents/Resources/transcription")
    }

    private static func makeProcess(arguments: [String]) throws -> Process {
        let runner = scriptsDirectory.appendingPathComponent("run.sh")
        guard FileManager.default.isExecutableFile(atPath: runner.path) else {
            throw NSError(domain: "Transcription", code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Встроенный скрипт не найден: " + runner.path])
        }
        let process = Process()
        process.executableURL = runner
        process.arguments = arguments
        return process
    }

    public static func checkDependencies(prepare: Bool = false,
        onOutput: (@Sendable (String) -> Void)? = nil) async throws -> (output: String, succeeded: Bool) {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let process = try makeProcess(arguments: [prepare ? "--prepare" : "--check"])
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try process.run()
                    let output = readOutput(from: pipe.fileHandleForReading, onOutput: onOutput)
                    process.waitUntilExit()
                    continuation.resume(returning: (output, process.terminationStatus == 0))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func readProgress(from handle: FileHandle, log: FileHandle,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) throws {
        var pending = Data()
        var discardingLine = false
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            try log.write(contentsOf: chunk)
            let parts = chunk.split(separator: 10, omittingEmptySubsequences: false)
            for part in parts.dropLast() {
                if !discardingLine, pending.count + part.count <= 65536 {
                    pending.append(contentsOf: part)
                    if let progress = TranscriptionProgress(line: pending) {
                        onProgress?(progress)
                    }
                }
                pending.removeAll(keepingCapacity: true)
                discardingLine = false
            }
            let tail = parts.last!
            if !discardingLine {
                if pending.count + tail.count <= 65536 {
                    pending.append(contentsOf: tail)
                } else {
                    pending.removeAll(keepingCapacity: true)
                    discardingLine = true
                }
            }
        }
        if !discardingLine, let progress = TranscriptionProgress(line: pending) { onProgress?(progress) }
    }

    static func readOutput(from handle: FileHandle, onOutput: (@Sendable (String) -> Void)?) -> String {
        var data = Data()
        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            data.append(chunk)
            if data.count > 65536 {
                // Retain complete lines so UTF-8 characters are never split at the start.
                if let newline = data.dropFirst(data.count - 32768).firstIndex(of: 10) {
                    data = Data(data.suffix(from: data.index(after: newline)))
                }
            }
            onOutput?(String(String(decoding: data, as: UTF8.self).suffix(12000)))
        }
        return String(String(decoding: data, as: UTF8.self).suffix(12000))
    }

}

public struct TranscriptionProgress: Decodable, Equatable, Sendable {
    public enum Stage: String, Decodable, Sendable {
        case gigaam, diarization, merge
    }

    public let stage: Stage
    public let channel: String?
    public let completed: Int
    public let total: Int

    init?(line: Data) {
        let prefix = Data("MEETING_PROGRESS ".utf8)
        guard line.starts(with: prefix),
              let value = try? JSONDecoder().decode(Self.self, from: line.dropFirst(prefix.count)),
              value.completed >= 0, value.total >= 0, value.completed <= value.total,
              value.channel == nil || value.channel == "host" || value.channel == "remote" else { return nil }
        self = value
    }

    public var text: String {
        let label: String
        switch stage {
        case .gigaam: label = "Распознавание речи"
        case .diarization: label = "Разделение голосов"
        case .merge: label = "Объединение дорожек"
        }
        let source = channel.map { $0 == "host" ? " · микрофон" : " · системный звук" } ?? ""
        let count = total > 1 ? " · \(completed)/\(total) окон" : ""
        return label + source + count + "…"
    }
}

public enum TranscriptionState: Equatable, Sendable {
    case idle
    case running(TranscriptionProgress?)
    case completed(URL)
    case failed(String)

    public var transcript: URL? {
        if case .completed(let url) = self { return url }
        return nil
    }

    public var text: String {
        switch self {
        case .idle: return ""
        case .running(let progress): return progress?.text ?? "Распознавание речи…"
        case .completed: return "Текст готов"
        case .failed(let message): return message
        }
    }
}

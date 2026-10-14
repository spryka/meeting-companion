import Foundation
import Darwin

public enum Transcription {
    private static let queue = DispatchQueue(label: "InterviewRecorder.transcription")

    public static func run(recording: URL) async throws -> URL {
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
                    process.standardOutput = handle
                    process.standardError = handle
                    try process.run()
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
        let installed = URL(fileURLWithPath: "/Applications/Meeting Companion.app/Contents/Resources/transcription")
        if FileManager.default.fileExists(atPath: installed.appendingPathComponent("run.sh").path) {
            return installed
        }
        return URL(fileURLWithPath: "/Applications/InterviewRecorder.app/Contents/Resources/transcription")
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

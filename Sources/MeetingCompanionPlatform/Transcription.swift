import Foundation
import Darwin
import os
import MeetingCompanionCore

public final class SubprocessRunner: @unchecked Sendable {
    public let process: Process
    private let lock = NSLock()
    private var isCancelled = false
    private var started = false
    private var terminationWorkItem: DispatchWorkItem?

    public init(process: Process) {
        self.process = process
    }

    /// Atomically check cancellation before running the process.
    /// If already cancelled, throws CancellationError without launching the process.
    public func start() throws {
        lock.lock()
        defer { lock.unlock() }
        if isCancelled {
            throw CancellationError()
        }
        try process.run()
        started = true
    }

    /// Returns true if cancelled either before start or while running.
    public var cancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isCancelled
    }

    /// Gracefully terminate with SIGTERM, then escalate to SIGKILL after timeoutSeconds (default: 2.0).
    /// Safe to call before start: marks cancelled so start() will fail atomically.
    public func terminate(timeoutSeconds: TimeInterval = 2.0) {
        lock.lock()
        isCancelled = true
        guard process.isRunning else {
            lock.unlock()
            return
        }

        process.terminate() // sends SIGTERM
        let pid = process.processIdentifier

        let item = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.lock.lock()
            defer { self.lock.unlock() }
            if self.process.isRunning {
                Darwin.kill(pid, SIGKILL)
            }
        }
        terminationWorkItem = item
        lock.unlock()

        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: item)
    }

    public func cancelTerminationTimer() {
        lock.lock()
        defer { lock.unlock() }
        terminationWorkItem?.cancel()
        terminationWorkItem = nil
    }
}

public enum Transcription {
    private static let queue = DispatchQueue(label: "MeetingCompanion.transcription")
    private static let voiceModelCheckQueue = DispatchQueue(label: "MeetingCompanion.voiceModelCheck", qos: .utility)

    public static func locateWorkerExecutable() -> URL? {
        if let env = ProcessInfo.processInfo.environment["MEETING_TRANSCRIPTION_WORKER"], !env.isEmpty {
            let url = URL(fileURLWithPath: env)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
        }

        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("MeetingTranscriptionWorker"),
            Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/MeetingTranscriptionWorker"),
            Bundle.main.resourceURL?.appendingPathComponent("MeetingTranscriptionWorker"),
            Bundle.main.resourceURL?.appendingPathComponent("transcription/MeetingTranscriptionWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/out/Products/Release/MeetingTranscriptionWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/out/Products/Debug/MeetingTranscriptionWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/arm64-apple-macosx/release/MeetingTranscriptionWorker"),
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/arm64-apple-macosx/debug/MeetingTranscriptionWorker"),
            URL(fileURLWithPath: "/Applications/Meeting Companion.app/Contents/MacOS/MeetingTranscriptionWorker")
        ]

        for candidate in candidates {
            if let candidate, FileManager.default.isExecutableFile(atPath: candidate.path) {
                return candidate
            }
        }
        return nil
    }

    private static func makeProcess(arguments: [String]) throws -> Process {
        guard let worker = locateWorkerExecutable() else {
            throw NSError(
                domain: "Transcription",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Встроенный исполняемый файл MeetingTranscriptionWorker не найден."]
            )
        }
        let process = Process()
        process.executableURL = worker
        process.arguments = arguments
        return process
    }

    public static func checkVoiceModel() async throws {
        _ = try await runVoiceWorker(arguments: ["--check-voice"], input: nil, on: voiceModelCheckQueue)
    }

    public static func prepareVoiceModel() async throws {
        _ = try await runVoiceWorker(arguments: ["--prepare-voice"], input: nil)
    }

    public static func extractVoiceEmbeddings(
        _ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL
    ) async throws -> VoiceEmbeddingProtocol.Response {
        try VoiceEmbeddingProtocol.validateRequest(request)
        let input = try JSONEncoder().encode(request)
        guard input.count <= VoiceEmbeddingProtocol.requestByteLimit else { throw VoiceEmbeddingProtocol.Invalid.request }
        let output = try await runVoiceWorker(arguments: ["--voice-embeddings", recordingDirectory.path], input: input)
        return try VoiceEmbeddingProtocol.decodeResponse(output, for: request)
    }

    private static func runVoiceWorker(arguments: [String], input: Data?, on workerQueue: DispatchQueue = queue) async throws -> Data {
        try await runVoiceWorker(process: makeProcess(arguments: arguments), input: input, on: workerQueue)
    }

    static func runVoiceWorker(process: Process, input: Data?, on workerQueue: DispatchQueue = queue) async throws -> Data {
        let runner = SubprocessRunner(process: process)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                workerQueue.async {
                    let inputPipe = Pipe()
                    let outputPipe = Pipe()
                    let inputWriter = inputPipe.fileHandleForWriting
                    let diagnostics = OSAllocatedUnfairLock(initialState: Data())
                    let diagnosticRead = DispatchGroup()
                    defer {
                        try? inputWriter.close()
                        diagnosticRead.wait()
                        runner.cancelTerminationTimer()
                    }
                    do {
                        guard fcntl(inputWriter.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                        process.standardInput = inputPipe
                        process.standardOutput = outputPipe
                        let errorPipe = input.map { _ in Pipe() }
                        process.standardError = errorPipe ?? outputPipe
                        try runner.start()
                        if let errorPipe {
                            DispatchQueue.global(qos: .utility).async(group: diagnosticRead) {
                                let reader = errorPipe.fileHandleForReading
                                defer { try? reader.close() }
                                let limit = 4096
                                var tail = Data()
                                while let chunk = try? reader.read(upToCount: limit), !chunk.isEmpty {
                                    tail.append(chunk)
                                    if tail.count > limit { tail.removeFirst(tail.count - limit) }
                                }
                                let diagnosticTail = tail
                                diagnostics.withLock { $0 = diagnosticTail }
                            }
                        }
                        let writeResult = Result { if let input { try inputWriter.write(contentsOf: input) } }
                        try inputWriter.close()
                        let limit = VoiceEmbeddingProtocol.responseByteLimit
                        let reader = outputPipe.fileHandleForReading
                        var output = Data()
                        while let chunk = try reader.read(upToCount: min(8192, limit - output.count + 1)),
                              !chunk.isEmpty {
                            output.append(chunk)
                            guard output.count <= limit else { throw VoiceEmbeddingProtocol.Invalid.response }
                        }
                        process.waitUntilExit()
                        if runner.cancelled { throw CancellationError() }
                        guard process.terminationStatus == 0 else {
                            diagnosticRead.wait()
                            let diagnosticOutput = input == nil ? output : diagnostics.withLock { $0 }
                            let detail = String(decoding: diagnosticOutput, as: UTF8.self)
                                .split(whereSeparator: \.isNewline).last.map(String.init)
                            let fallback = input == nil ? "Не удалось проверить или подготовить модель голосов." :
                                "Не удалось получить признаки голоса."
                            throw NSError(domain: "VoiceEmbeddings", code: Int(process.terminationStatus),
                                userInfo: [NSLocalizedDescriptionKey: detail ?? fallback])
                        }
                        try writeResult.get()
                        continuation.resume(returning: output)
                    } catch {
                        let cancelled = runner.cancelled
                        if process.isRunning {
                            runner.terminate(timeoutSeconds: 2)
                            process.waitUntilExit()
                        }
                        continuation.resume(throwing: cancelled ? CancellationError() : error)
                    }
                }
            }
        } onCancel: {
            runner.terminate(timeoutSeconds: 2)
        }
    }

    public static func run(
        recording: URL,
        parakeet: Bool = false,
        echoCancellation: Bool = false,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)? = nil
    ) async throws -> URL {
        try await Task.detached { try RecordingPaths.requireStandardLayout(recording) }.value
        let process = try makeProcess(arguments: ["--recording", "--offline"] +
            (parakeet ? ["--parakeet"] : []) +
            (echoCancellation ? ["--echo-cancel"] : []) + [recording.path])
        let runner = SubprocessRunner(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let storage = TranscriptResultStorage(recordingURL: recording)
                        let previousID = try storage.currentResultDirectory()?.lastPathComponent
                        let base = recording.deletingPathExtension()
                        let raw = recording.deletingLastPathComponent().appendingPathComponent("raw")
                        let logBase = FileManager.default.fileExists(atPath: raw.path)
                            ? raw.appendingPathComponent(base.lastPathComponent) : base
                        var log = logBase.appendingPathExtension("transcription.log")
                        if FileManager.default.fileExists(atPath: log.path) {
                            log = logBase.appendingPathExtension("transcription-" + UUID().uuidString + ".log")
                        }
                        let descriptor = Darwin.open(log.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                        guard descriptor >= 0 else {
                            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                        }
                        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
                        defer { try? handle.close() }

                        let pipe = Pipe()
                        process.standardOutput = pipe
                        process.standardError = pipe
                        try runner.start()
                        var readError: Error?
                        do {
                            try readProgress(from: pipe.fileHandleForReading, log: handle, onProgress: onProgress)
                        } catch {
                            runner.terminate(timeoutSeconds: 2.0)
                            process.waitUntilExit()
                            runner.cancelTerminationTimer()
                            readError = error
                        }
                        process.waitUntilExit()
                        runner.cancelTerminationTimer()

                        if let transcript = try storage.committedText(after: previousID) {
                            if runner.cancelled || process.terminationStatus != 0 || readError != nil {
                                onProgress?(TranscriptionProgress(stage: .warning, completed: 0, total: 1,
                                    warning: "Новый результат сохранён, но подтверждение обработки прервано. " + (readError?.localizedDescription ?? "")))
                            }
                            continuation.resume(returning: transcript)
                            return
                        }
                        if runner.cancelled { throw CancellationError() }
                        if let readError { throw readError }
                        let status = process.terminationReason == .uncaughtSignal
                            ? "Процесс остановлен сигналом \(process.terminationStatus)."
                            : "Код завершения: \(process.terminationStatus)."
                        let detail = failureDetail(log: log).map { " Последняя ошибка: " + $0 } ?? ""
                        throw NSError(domain: "Transcription", code: Int(process.terminationStatus),
                            userInfo: [NSLocalizedDescriptionKey: "Новый результат не опубликован. " + status + detail + " Подробности: " + log.path])
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            runner.terminate(timeoutSeconds: 2.0)
        }
    }

    public static func failureDetail(log: URL) -> String? {
        guard let file = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? file.close() }
        guard let size = try? file.seekToEnd() else { return nil }
        do {
            try file.seek(toOffset: size > 8192 ? size - 8192 : 0)
            let tail = String(decoding: try file.read(upToCount: 8192) ?? Data(), as: UTF8.self)
            return tail.components(separatedBy: .newlines).last {
                !$0.hasPrefix("MEETING_PROGRESS ") && ($0.contains("Error:") || $0.contains("Exception:") || $0.contains("error:"))
            }.map { String($0.prefix(1000)) }
        } catch { return nil }
    }

    public static func checkDependencies(
        prepare: Bool = false,
        availability: Bool = false,
        parakeet: Bool = false,
        onOutput: (@Sendable (String) -> Void)? = nil
    ) async throws -> (output: String, succeeded: Bool) {
        let process = try makeProcess(arguments: [prepare ? "--prepare" : availability ? "--availability" : "--check"] +
            (parakeet ? ["--parakeet"] : []))
        let runner = SubprocessRunner(process: process)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    do {
                        let pipe = Pipe()
                        process.standardOutput = pipe
                        process.standardError = pipe
                        try runner.start()
                        let output = readOutput(from: pipe.fileHandleForReading, onOutput: onOutput)
                        process.waitUntilExit()
                        runner.cancelTerminationTimer()
                        if runner.cancelled {
                            throw CancellationError()
                        }
                        continuation.resume(returning: (output, process.terminationStatus == 0))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        } onCancel: {
            runner.terminate(timeoutSeconds: 2.0)
        }
    }

    public static func readProgress(
        from handle: FileHandle,
        log: FileHandle,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) throws {
        var pending = Data()
        var discardingLine = false
        var previous: TranscriptionProgress?
        var lastPublished = ContinuousClock.now

        func publish(_ progress: TranscriptionProgress) {
            let now = ContinuousClock.now
            if let previous, previous.stage == progress.stage, previous.channel == progress.channel,
               previous.step == progress.step, progress.warning == nil, progress.state == nil,
               progress.completed != progress.total, now - lastPublished < .milliseconds(500) { return }
            previous = progress
            lastPublished = now
            onProgress?(progress)
        }

        while true {
            let chunk = handle.availableData
            guard !chunk.isEmpty else { break }
            try log.write(contentsOf: chunk)
            let parts = chunk.split(separator: 10, omittingEmptySubsequences: false)
            for part in parts.dropLast() {
                if !discardingLine, pending.count + part.count <= 65536 {
                    pending.append(contentsOf: part)
                    if let progress = TranscriptionProgress(line: pending) {
                        publish(progress)
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
        if !discardingLine, let progress = TranscriptionProgress(line: pending) { publish(progress) }
    }

    public static func readOutput(from handle: FileHandle, onOutput: (@Sendable (String) -> Void)?) -> String {
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

import Foundation
import MeetingCompanionCore

final class ProgressProbe: @unchecked Sendable {
    var events: [TranscriptionProgress] = []
    var arrivedBeforeExit = false
}

@main struct Check {
    static func emitFixture() throws {
        let output = FileHandle.standardOutput
        func write(_ text: String) { output.write(Data(text.utf8)) }
        func event(_ changes: [String: Any] = [:]) throws -> String {
            var payload: [String: Any] = ["stage": "gigaam", "channel": "host", "completed": 1, "total": 2]
            payload.merge(changes) { _, new in new }
            return "MEETING_PROGRESS " + String(decoding: try JSONSerialization.data(withJSONObject: payload, options: .sortedKeys), as: UTF8.self)
        }
        write("Обычный лог\n")
        let first = try event()
        write(String(first.prefix(23)))
        Thread.sleep(forTimeInterval: 0.1)
        write(String(first.dropFirst(23)) + "\n")
        for change: [String: Any] in [["stage": "unknown"], ["channel": "unknown"], ["completed": -1], ["completed": 3], ["total": 1.5]] {
            write(try event(change) + "\n")
        }
        // An overlong line must not become valid when its prefix is discarded.
        write(String(repeating: "x", count: 70000))
        Thread.sleep(forTimeInterval: 0.1)
        write(try event() + "\n")
        write(try event(["completed": 2]) + "\n")
        write(try event(["stage": "diarization", "completed": 0, "total": 1]) + "\n")
        Thread.sleep(forTimeInterval: 0.1)
        write(try event(["stage": "merge", "channel": NSNull(), "completed": 1, "total": 1]))
    }

    static func main() throws {
        if CommandLine.arguments.dropFirst().first == "--emit-fixture" { try emitFixture(); return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("transcription.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        process.arguments = ["--emit-fixture"]
        let pipe = Pipe()
        process.standardOutput = pipe
        let probe = ProgressProbe()
        try process.run()
        try Transcription.readProgress(from: pipe.fileHandleForReading, log: handle) { event in
            probe.events.append(event)
            probe.arrivedBeforeExit = probe.arrivedBeforeExit || process.isRunning
        }
        process.waitUntilExit()
        precondition(process.terminationStatus == 0)
        precondition(probe.events.count == 4 && probe.arrivedBeforeExit)
        precondition(probe.events.map(\.stage) == [.gigaam, .gigaam, .diarization, .merge])
        precondition(probe.events[0].text.contains("1/2 окон"))
        precondition(probe.events[2].text.contains("микрофон"))
        let contents = try String(contentsOf: log, encoding: .utf8)
        precondition(contents.contains("Обычный лог") && contents.contains(String(repeating: "x", count: 70000)))
        precondition(contents.hasSuffix("\"total\":1}"))
        precondition(Transcription.failureDetail(log: log) == nil)
        let failureLog = directory.appendingPathComponent("failure.log")
        try (String(repeating: "ignored\n", count: 2000) + "RuntimeError: model unavailable\nMEETING_PROGRESS {}\n").write(to: failureLog, atomically: true, encoding: .utf8)
        precondition(Transcription.failureDetail(log: failureLog) == "RuntimeError: model unavailable")
        precondition(Transcription.failureDetail(log: directory.appendingPathComponent("missing")) == nil)
        let transcript = directory.appendingPathComponent("result.txt")
        precondition(TranscriptionState.idle.transcript == nil)
        precondition(TranscriptionState.running(probe.events[0]).text == probe.events[0].text)
        precondition(TranscriptionState.completed(transcript).transcript == transcript)
        precondition(TranscriptionState.failed("error").text == "error")
        let speakerEvent = Data("MEETING_PROGRESS {\"stage\":\"speakers\",\"channel\":\"remote\",\"completed\":500,\"total\":1000,\"step\":10,\"steps\":13}".utf8)
        let speakers = TranscriptionProgress(line: speakerEvent)!
        precondition(speakers.stage == .speakers && speakers.text.contains("500/1000 слов"))
        precondition(speakers.completedSteps == 9 && speakers.stageFraction == 0.5)
        let finished = TranscriptionProgress(line: Data("MEETING_PROGRESS {\"stage\":\"merge\",\"completed\":1,\"total\":1,\"step\":13,\"steps\":13}".utf8))!
        precondition(finished.completedSteps == 13 && finished.stageFraction == 1)
        let started = TranscriptionProgress(line: Data("MEETING_PROGRESS {\"stage\":\"gigaam\",\"completed\":0,\"total\":32,\"step\":1,\"steps\":13}".utf8))!
        precondition(started.completedSteps == 0 && started.stageFraction == 0)
        let unknown = TranscriptionProgress(line: Data("MEETING_PROGRESS {\"stage\":\"diarization\",\"completed\":0,\"total\":0}".utf8))!
        precondition(unknown.stageFraction == nil && unknown.completedSteps == nil)
        print("Progress: partial lines, invalid events, bounded parsing, full log and processing state passed")
    }
}

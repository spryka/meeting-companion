import Foundation

final class ProgressProbe: @unchecked Sendable {
    var events: [TranscriptionProgress] = []
    var arrivedBeforeExit = false
}

@main struct Check {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = directory.appendingPathComponent("transcription.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let handle = try FileHandle(forWritingTo: log)
        defer { try? handle.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = ["-u", "-c", """
import json, sys, time
prefix = 'MEETING_PROGRESS '
def event(**changes):
    payload = dict(stage='gigaam', channel='host', completed=1, total=2)
    payload.update(changes)
    return prefix + json.dumps(payload)
print('Обычный лог', flush=True)
first = event()
sys.stdout.write(first[:23]); sys.stdout.flush()
time.sleep(0.1)
sys.stdout.write(first[23:] + '\\n'); sys.stdout.flush()
for change in [dict(stage='unknown'), dict(channel='unknown'), dict(completed=-1),
               dict(completed=3), dict(total=1.5)]:
    print(event(**change), flush=True)
# An overlong line must not become a valid event when its prefix is discarded.
sys.stdout.write('x' * 70000); sys.stdout.flush()
time.sleep(0.1)
print(event(), flush=True)
print(event(completed=2), flush=True)
print(event(stage='diarization', completed=0, total=1), flush=True)
time.sleep(0.1)
sys.stdout.write(event(stage='merge', channel=None, completed=1, total=1)); sys.stdout.flush()
"""]
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
        precondition(contents.hasSuffix("\"total\": 1}"))
        let transcript = directory.appendingPathComponent("result.txt")
        precondition(TranscriptionState.idle.transcript == nil)
        precondition(TranscriptionState.running(probe.events[0]).text == probe.events[0].text)
        precondition(TranscriptionState.completed(transcript).transcript == transcript)
        precondition(TranscriptionState.failed("error").text == "error")
        print("Progress: partial lines, invalid events, bounded parsing, full log and processing state passed")
    }
}

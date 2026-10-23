import Foundation
import Combine

@main
struct RecordingHistoryChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count == 2 {
            let entry = RecordingEntry.load(recording: URL(fileURLWithPath: CommandLine.arguments[1]))
            print(entry.title, entry.status)
            for problem in entry.problems { print(problem.stage.title + ": " + problem.message) }
            return
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let emptyHistory = RecordingHistory()
        await emptyHistory.refresh(root: root)
        precondition(emptyHistory.entries.isEmpty && !emptyHistory.loading && emptyHistory.initialLoadComplete && emptyHistory.error == nil,
                     "A missing recordings directory must finish loading without an error")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        await emptyHistory.refresh(root: root)
        precondition(emptyHistory.entries.isEmpty && !emptyHistory.loading && emptyHistory.initialLoadComplete && emptyHistory.error == nil,
                     "An empty recordings directory must finish loading without an error")
        let folder = root.appendingPathComponent("2026-10/21/meeting_2026-10-21_10-01-31")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("meeting_2026-10-21_10-01-31.m4a")
        var entry = RecordingEntry.load(recording: recording)
        try Data("Transcript: test\nWarning: Nemotron достиг лимита\n\n[00:01] Speaker 1: text\n".utf8).write(to: entry.transcript)
        try Data(#"{"summary":"Meeting","start":"2026-10-21T07:00:00Z","end":"2026-10-21T08:00:00Z","agenda":"Agenda","attendees":["Person"],"links":[]}"#.utf8).write(to: entry.context)
        try Data(#"{"droppedBuffers":0,"microphoneRecoveries":1,"microphoneRecoveryEvents":[{"timestamp":65,"reason":"Configuration changed"}]}"#.utf8).write(to: entry.captureReport)
        entry = RecordingEntry.load(recording: recording)
        precondition(entry.phase == .completed && entry.title == "Meeting")
        precondition(entry.meeting?.attendees == ["Person"])
        precondition(entry.problems.contains { $0.message == "[01:05] Configuration changed" })
        precondition(entry.problems.contains { $0.message.contains("Nemotron") })
        precondition(entry.problems.allSatisfy { !$0.isError })

        let history = RecordingHistory()
        history.put(entry)
        history.update(recording) { $0.phase = .processing }
        let interrupted = RecordingEntry.load(recording: recording)
        precondition(interrupted.phase == .interrupted, "An old transcript must not hide an interrupted retry")
        precondition(interrupted.problems.contains { $0.message.contains("Приложение завершилось") })
        history.update(recording) { $0.phase = .completed }
        precondition(RecordingEntry.load(recording: recording).phase == .completed)
        let imported = RecordingHistory()
        await imported.refresh(root: root)
        precondition(imported.entries.count == 1 && imported.entries[0].phase == .completed)
        precondition(imported.entries[0].problems == entry.problems)

        history.update(recording) { $0.phase = .recording }
        await history.refresh(root: root)
        precondition(history.entry(recording)?.phase == .recording, "A disk scan must not replace live state")
        history.update(recording) { $0.phase = .failed; $0.addProblem(.transcription, "Model failure", error: true) }
        let failed = RecordingEntry.load(recording: recording)
        precondition(failed.phase == .failed && failed.problems.contains { $0.isError && $0.message == "Model failure" })

        let old = root.appendingPathComponent("2026-10/21/meeting_2026-10-21_09-00-00.sources.transcript.txt")
        try Data("[00:01] Speaker 1: legacy\n".utf8).write(to: old)
        let experiment = root.appendingPathComponent("experiments/meeting_2026-10-21_12-00-00")
        try FileManager.default.createDirectory(at: experiment, withIntermediateDirectories: true)
        let initialLoad = RecordingHistory()
        var publishedCounts: [Int] = []
        let observation = initialLoad.$entries.dropFirst().sink { publishedCounts.append($0.count) }
        await initialLoad.refresh(root: root)
        precondition(publishedCounts == [2], "First load must publish one complete snapshot, not individual rows")
        precondition(initialLoad.entries.map(\.date) == initialLoad.entries.map(\.date).sorted(by: >))
        observation.cancel()
        await imported.refresh(root: root)
        precondition(imported.entries.count == 2, "Read legacy recordings; skip experiments")
        precondition(imported.entry(recording)?.phase == .failed, "Refresh must read updated on-disk outcomes")

        let failedBase = old.deletingLastPathComponent().appendingPathComponent("meeting_2026-10-21_08-00-00")
        let failureLog = failedBase.appendingPathExtension("transcription.log")
        try Data("Traceback\nRuntimeError: missing model\n".utf8).write(to: failureLog)
        let legacyFailure = RecordingEntry.load(recording: failedBase.appendingPathExtension("m4a"))
        precondition(legacyFailure.phase == .failed && legacyFailure.problems.contains { $0.message == "RuntimeError: missing model" })
        precondition(legacyFailure.log?.lastPathComponent == failureLog.lastPathComponent)

        let source = "Host audio: /Users/example/Meetings/raw/a.host.wav\nRemote audio: /Users/example/Meetings/raw/a.remote.wav\nWarning: failed /Users/example/cache/model\n[00:01] Speaker 1: /Users/example was spoken\n"
        let shared = RecordingEntry.shareableTranscript(source)
        precondition(shared.contains("Host audio: raw/a.host.wav"))
        precondition(shared.contains("Warning: failed ~/cache/model"))
        precondition(shared.contains("[00:01] Speaker 1: /Users/example was spoken"), "Do not rewrite meeting speech")
        precondition(RecordingEntry.shareableTranscript(shared) == shared)
        let queue = RecordingWorkQueue()
        var timeline: [String] = []
        var releaseFirst: CheckedContinuation<Void, Never>?
        queue.enqueue {
            timeline.append("first-start")
            await withCheckedContinuation { releaseFirst = $0 }
            timeline.append("first-end")
        }
        queue.enqueue { timeline.append("second") }
        while releaseFirst == nil { await Task.yield() }
        precondition(timeline == ["first-start"], "Jobs must not overlap")
        queue.enqueue { timeline.append("third") }
        releaseFirst?.resume()
        while queue.isRunning { await Task.yield() }
        precondition(timeline == ["first-start", "first-end", "second", "third"])
        queue.enqueue { timeline.append("after-idle") }
        while queue.isRunning { await Task.yield() }
        precondition(timeline.last == "after-idle", "Queue must restart after becoming empty")
        print("Recording history, independent failures, persistence, private-path export and serial FIFO queue checks passed")
    }
}

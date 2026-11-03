import Testing
import Foundation
import MeetingCompanionCore
@testable import MeetingTranscriptionPipeline
@testable import MeetingCompanionPlatform

@Suite("PipelineLogic Tests")
struct PipelineLogicTests {

    @Test(arguments: [[1, 1, 1, 2], [nil, nil, nil, 1]])
    func cascadeRejectsMixedOriginalSpeakerCandidates(speakers: [Int?]) {
        let words = zip(["alpha", "beta", "gamma", "delta"], speakers).enumerated().map { index, pair in
            PipelineWord(start: Double(index), end: Double(index + 1), text: pair.0, speaker: pair.1)
        }
        let (corrected, journal) = PipelineLogic.cascade(words, [
            PipelineWord(start: 0, end: 4, text: "alpha beta gamma delta")
        ])
        #expect(!journal.isEmpty)
        #expect(journal.allSatisfy { row in
            let span = words[row.source_indices[0]..<row.source_indices[1]]
            return span.allSatisfy { $0.speaker == span.first!.speaker }
        })
        #expect(corrected.last?.speaker == speakers.last!)
        #expect(corrected.last?.start == 3)
    }

    @Test func cascadeStillAppliesSameSpeakerCorrection() {
        let words = ["alfa", "beta", "gamma", "delta"].enumerated().map { index, text in
            PipelineWord(start: Double(index), end: Double(index + 1), text: text, speaker: 2)
        }
        let (corrected, journal) = PipelineLogic.cascade(words, [
            PipelineWord(start: 0, end: 4, text: "alpha beta gamma delta")
        ])
        #expect(corrected == [PipelineWord(start: 0, end: 4, text: "alpha beta gamma delta", speaker: 2)])
        #expect(journal.contains { $0.applied && $0.source_indices == [0, 4] })
    }

    @Test func resolverKeepsRecordingIdentityAndRequiresExactRawPair() throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = scratch.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let owner = root.appendingPathComponent("meeting.m4a")
        try Data([1]).write(to: owner)
        let other = root.appendingPathComponent("other.m4a")
        try FileManager.default.createSymbolicLink(at: other, withDestinationURL: owner)
        for source in ["host", "remote"] {
            try Data([2]).write(to: root.appendingPathComponent("raw/meeting." + source + "_record.wav"))
        }
        #expect(try RecordingSourceResolver.resolve(recordingPath: owner.path).stem == "meeting")
        #expect(try RecordingSourceResolver.resolve(recordingPath: root.path).stem == "meeting")
        #expect(throws: Error.self) { try RecordingSourceResolver.resolve(recordingPath: other.path) }
        let host = root.appendingPathComponent("raw/meeting.host_record.wav")
        try FileManager.default.removeItem(at: host)
        let outside = scratch.appendingPathComponent("outside.wav")
        try Data([3]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: host, withDestinationURL: outside)
        #expect(throws: Error.self) { try RecordingSourceResolver.resolve(recordingPath: owner.path) }
        try FileManager.default.removeItem(at: host)
        for source in ["host", "remote"] {
            try Data([2]).write(to: root.appendingPathComponent("meeting." + source + "_record.wav"))
        }
        #expect(throws: RecordingResolverError.self) { try RecordingSourceResolver.resolve(recordingPath: owner.path) }
    }

    @Test func testAssembleBasicWords() throws {
        let tokens = [
            ASRToken(id: 1, piece: " При", start: 0.1, end: 0.3),
            ASRToken(id: 2, piece: "вет", start: 0.3, end: 0.5),
            ASRToken(id: 3, piece: " мир", start: 0.6, end: 0.9)
        ]
        let words = try PipelineLogic.assemble(tokens, start: 0.0, end: 10.0, last: true)
        #expect(words.count == 2)
        #expect(words[0].text == "Привет")
        #expect(words[1].text == "мир")
        #expect(words[0].start == 0.1)
        #expect(words[0].end == 0.5)
        #expect(words[1].start == 0.6)
        #expect(words[1].end == 0.9)
    }

    @Test func testAssembleInvalidTimestampsThrows() {
        let tokens = [
            ASRToken(id: 1, piece: " Слово", start: 5.0, end: 4.0) // end < start
        ]
        #expect(throws: PipelineError.self) {
            _ = try PipelineLogic.assemble(tokens, start: 0.0, end: 10.0, last: true)
        }
    }

    @Test func testPhoneticSimilarity() {
        let simIdentical = PipelineLogic.similarity("кошка", "кошка")
        #expect(simIdentical == 1.0)

        let simClose = PipelineLogic.similarity("онбординг", "онбордин")
        #expect(simClose > 0.8)

        let simDifferent = PipelineLogic.similarity("компьютер", "яблоко")
        #expect(simDifferent < 0.3)
    }

    @Test func testAssignSpeakersIntervals() {
        let words = [
            PipelineWord(start: 1.0, end: 2.0, text: "Раз"),
            PipelineWord(start: 3.5, end: 4.5, text: "Два")
        ]
        let intervals = [
            DiarizationInterval(start: 0.5, end: 2.5, speaker: 10),
            DiarizationInterval(start: 3.0, end: 5.0, speaker: 20)
        ]

        let assigned = PipelineLogic.assign(words, intervals)
        #expect(assigned.count == 2)
        #expect(assigned[0].speaker == 1) // first distinct speaker remapped to 1
        #expect(assigned[1].speaker == 2) // second distinct speaker remapped to 2
    }

    @Test func testGroupTurnsPunctuationAndPause() {
        // Test 1: Pause >= 2.0s triggers split
        let wordsWithPause = [
            PipelineWord(start: 0.0, end: 1.0, text: "Первая", speaker: 1),
            PipelineWord(start: 3.5, end: 4.5, text: "Вторая", speaker: 1) // gap = 2.5s >= 2.0s
        ]
        let turnsPause = PipelineLogic.groupTurns(wordsWithPause)
        #expect(turnsPause.count == 2)

        // Test 2: Punctuation split after 15s
        let wordsPunct = [
            PipelineWord(start: 0.0, end: 5.0, text: "Начало", speaker: 1),
            PipelineWord(start: 5.5, end: 15.5, text: "предложения.", speaker: 1),
            PipelineWord(start: 16.0, end: 17.0, text: "Продолжение", speaker: 1)
        ]
        let turnsPunct = PipelineLogic.groupTurns(wordsPunct)
        #expect(turnsPunct.count == 2)
        #expect(turnsPunct[0].text == "Начало предложения.")
        #expect(turnsPunct[1].text == "Продолжение")
    }

    @Test func testGroupTurnIndices() {
        let words = [
            PipelineWord(start: 0.0, end: 1.0, text: "Слово1", speaker: 1),
            PipelineWord(start: 1.2, end: 2.0, text: "Слово2", speaker: 1),
            PipelineWord(start: 4.5, end: 5.0, text: "Слово3", speaker: 1) // 2.5s pause
        ]
        let groups = PipelineLogic.groupTurnIndices(words)
        #expect(groups.count == 2)
        #expect(groups[0] == [0, 1])
        #expect(groups[1] == [2])
    }

    @Test func testMergedTurnsChannelOffset() {
        let hostWords = [PipelineWord(start: 0.0, end: 1.0, text: "Привет", speaker: 1)]
        let remoteWords = [PipelineWord(start: 1.5, end: 2.5, text: "Здравствуйте", speaker: 1)]

        let merged = PipelineLogic.mergeTwoChannels(host: hostWords, remote: remoteWords)
        #expect(merged.count == 2)
        #expect(merged[0].speaker == 1)
        #expect(merged[1].speaker == 2) // Remote speaker shifted by host max
        #expect(merged[0].text == "Привет")
        #expect(merged[1].text == "Здравствуйте")
    }
}

@Suite("SubprocessRunner Cancellation Tests", .serialized)
struct SubprocessRunnerCancellationTests {

    @Test func testPreStartCancellationPreventsProcessLaunch() throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = ["60"]
        let runner = SubprocessRunner(process: process)

        // Cancel before start() is called
        runner.terminate(timeoutSeconds: 2.0)
        #expect(runner.cancelled == true)

        // Calling start() now must throw CancellationError atomically without launching process
        #expect(throws: CancellationError.self) {
            try runner.start()
        }
        #expect(process.isRunning == false)
    }

    @Test func testRunningChildIgnoringSIGTERMIsKilledWithinTwoSeconds() async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        let pipe = Pipe()
        process.standardOutput = pipe
        // Trap and ignore SIGTERM, then write READY to pipe to ensure trap is active
        process.arguments = ["-c", "trap \"\" TERM; echo READY; while true; do sleep 0.05; done"]
        let runner = SubprocessRunner(process: process)

        try runner.start()
        #expect(process.isRunning == true)

        defer {
            // Cleanup even on assertion failure
            if process.isRunning {
                Darwin.kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
            }
        }

        // Bounded readiness handshake AFTER trap installation
        let handle = pipe.fileHandleForReading
        var readyData = Data()
        let handshakeDeadline = ContinuousClock.now + .seconds(2)
        while ContinuousClock.now < handshakeDeadline {
            let available = handle.availableData
            if !available.isEmpty {
                readyData.append(available)
                if let str = String(data: readyData, encoding: .utf8), str.contains("READY") {
                    break
                }
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let readyString = String(data: readyData, encoding: .utf8) ?? ""
        #expect(readyString.contains("READY"))

        let startTime = ContinuousClock.now
        // Terminate with 0.5s timeout: will send SIGTERM, wait 0.5s, then escalate to SIGKILL
        runner.terminate(timeoutSeconds: 0.5)

        // Wait for process to exit
        let deadline = ContinuousClock.now + .seconds(3)
        while process.isRunning && ContinuousClock.now < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        process.waitUntilExit()

        let elapsed = ContinuousClock.now - startTime
        #expect(process.isRunning == false)
        #expect(elapsed >= .milliseconds(450)) // Proves child did not exit prematurely on SIGTERM
        #expect(elapsed < .seconds(2.0))
        #expect(process.terminationReason == .uncaughtSignal)
        #expect(process.terminationStatus == SIGKILL)
        #expect(runner.cancelled == true)
    }

    @Test func testAsyncPublicAPICancellationPropagatesError() async throws {
        // Create an isolated dummy worker script that simulates long-running dependency check
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let dummyWorker = tempDir.appendingPathComponent("MeetingTranscriptionWorker")
        let scriptContent = "#!/bin/sh\nsleep 10\nexit 0\n"
        try scriptContent.write(to: dummyWorker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dummyWorker.path)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        // Point MEETING_TRANSCRIPTION_WORKER to dummy worker to avoid installed app or model dependency
        setenv("MEETING_TRANSCRIPTION_WORKER", dummyWorker.path, 1)
        defer { unsetenv("MEETING_TRANSCRIPTION_WORKER") }

        let task = Task {
            try await Transcription.checkDependencies(availability: true)
        }
        // Cancel the task immediately
        task.cancel()

        var caughtCancellation = false
        do {
            _ = try await task.value
            Issue.record("Expected CancellationError, but task completed successfully")
        } catch is CancellationError {
            caughtCancellation = true
        } catch {
            Issue.record("Expected CancellationError, but caught \(error)")
        }
        #expect(caughtCancellation == true)
    }
    @Test func flatPlatformRunnerRejectsBeforeWorkerAndLog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worker = root.appendingPathComponent("synthetic-worker")
        let marker = root.appendingPathComponent("worker-started")
        try ("#!/bin/sh\n/usr/bin/touch '" + marker.path + "'\nexit 7\n").write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        let previous = ProcessInfo.processInfo.environment["MEETING_TRANSCRIPTION_WORKER"]
        setenv("MEETING_TRANSCRIPTION_WORKER", worker.path, 1)
        defer { if let previous { setenv("MEETING_TRANSCRIPTION_WORKER", previous, 1) } else { unsetenv("MEETING_TRANSCRIPTION_WORKER") } }
        await #expect(throws: Error.self) { try await Transcription.run(recording: root.appendingPathComponent("flat.m4a")) }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("flat.transcription.log").path))
    }

    @Test func flatRecorderRejectsLayoutBeforeCheckingCaptureFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let output = root.appendingPathComponent("flat.m4a")
        // Existing output prevents beta6 from creating any capture/device even without the new guard.
        try Data([1]).write(to: output)
        do {
            _ = try await Recorder(outputURL: output)
            Issue.record("Flat Recorder.init must reject")
        } catch { #expect((error as NSError).code == CocoaError.fileWriteInvalidFileName.rawValue) }
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("raw").path))
        #expect(try Data(contentsOf: output) == Data([1]))
    }

    @Test(arguments: ["success", "ack", "cancel", "noCommit"])
    func actualRunnerAcknowledgesOnlyNewCommittedText(kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let preparedRoot = root.appendingPathComponent("prepared")
        let recordingRoot = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: preparedRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: recordingRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("transcription/fixtures/transcript-document/valid_parakeet_off.json")
        let document = try TranscriptDocument.load(from: fixture, recordingDirectory: recordingRoot)
        let prepared = try TranscriptPublisher(recordingDirectory: preparedRoot).publish(document: document, audioMixData: Data([1])).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: recordingRoot.appendingPathComponent("raw/transcripts"), withIntermediateDirectories: true)
        let recording = recordingRoot.appendingPathComponent("meeting.m4a")
        let staleText = recordingRoot.appendingPathComponent("meeting.sources.transcript.txt")
        try Data("STALE ROOT TXT".utf8).write(to: staleText)
        let target = recordingRoot.appendingPathComponent("raw/transcripts/" + document.resultID)
        let worker = root.appendingPathComponent("synthetic-worker")
        let move = kind == "noCommit" ? "" : "/bin/mv '\(prepared.path)' '\(target.path)'\n"
        let notification = "MEETING_PROGRESS {\"stage\":\"warning\",\"completed\":0,\"total\":1,\"warning\":\"COMMITTED\"}"
        let end = kind == "cancel" ? "exec /bin/sleep 10" : "exit \(kind == "ack" ? 7 : 0)"
        try ("#!/bin/sh\n" + move + "printf '%s\\n' '" + notification + "'\n" + end + "\n").write(to: worker, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: worker.path)
        let previousWorker = ProcessInfo.processInfo.environment["MEETING_TRANSCRIPTION_WORKER"]
        setenv("MEETING_TRANSCRIPTION_WORKER", worker.path, 1)
        defer {
            if let previousWorker { setenv("MEETING_TRANSCRIPTION_WORKER", previousWorker, 1) }
            else { unsetenv("MEETING_TRANSCRIPTION_WORKER") }
        }
        let (events, continuation) = AsyncStream<TranscriptionProgress>.makeStream()
        let task = Task { try await Transcription.run(recording: recording, onProgress: { continuation.yield($0) }) }
        if kind == "cancel" {
            for await progress in events where progress.warning == "COMMITTED" { task.cancel(); break }
        }
        if kind == "noCommit" {
            do { _ = try await task.value; Issue.record("exit0 with stale root TXT must not acknowledge a new result") }
            catch { #expect(!(error is CancellationError)) }
        } else {
            let text = try await task.value
            #expect(text.path == target.appendingPathComponent("transcript.txt").path)
            #expect(try String(contentsOf: text, encoding: .utf8) != "STALE ROOT TXT")
        }
        continuation.finish()
        #expect(try String(contentsOf: staleText, encoding: .utf8) == "STALE ROOT TXT")
    }

}

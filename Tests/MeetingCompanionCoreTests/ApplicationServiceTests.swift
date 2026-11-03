import Testing
import Foundation
@testable import MeetingCompanionApplication
@testable import MeetingCompanionCore

// MARK: - Mocks & Stubs

private final class MockTranscriptionRunner: TranscriptionRunnerProtocol, @unchecked Sendable {
    var checkResult: Bool = true
    var checkOutput: String = "All dependencies satisfied."
    var delayNanoseconds: UInt64 = 50_000_000 // 50ms
    var shouldFail: Bool = false
    var failureErrorDescription: String = "Mock ASR Failure"
    var capturedSettings: (parakeet: Bool, echoCancellation: Bool)?
    var runCallCount: Int = 0
    var onRun: (@Sendable () async throws -> Void)?
    var onCheckDependencies: (@Sendable () async -> Void)? = nil

    func checkDependencies(availability: Bool, parakeet: Bool) async throws -> Bool {
        return checkResult
    }

    func checkDependenciesWithOutput(
        prepare: Bool,
        availability: Bool,
        parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?
    ) async throws -> (output: String, succeeded: Bool) {
        if let onCheckDependencies {
            await onCheckDependencies()
        }
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        onOutput?(checkOutput)
        return (output: checkOutput, succeeded: checkResult)
    }

    func run(
        recording: URL,
        parakeet: Bool,
        echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?
    ) async throws -> URL {
        try await onRun?()
        runCallCount += 1
        capturedSettings = (parakeet, echoCancellation)
        if delayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: delayNanoseconds)
        }
        if shouldFail {
            throw NSError(domain: "MockTranscriptionRunner", code: 42, userInfo: [NSLocalizedDescriptionKey: failureErrorDescription])
        }
        return recording.deletingPathExtension().appendingPathExtension("json")
    }
}

private final class MockAudioExporter: AudioExporterProtocol, @unchecked Sendable {
    var shouldFail: Bool = false
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws {
        if shouldFail {
            throw NSError(domain: "MockAudioExporter", code: 99, userInfo: [NSLocalizedDescriptionKey: "Mock Export Failure"])
        }
    }
}

private final class MockAudioCaptureController: AudioCaptureControllerProtocol, @unchecked Sendable {
    var duration: TimeInterval = 15.0
    var outputURL: URL
    var warnings: [String] = []
    var isStarted = false
    var isMuted = false
    var startDelayNanoseconds: UInt64 = 0
    var onStartCapture: (() throws -> Void)?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func startCapture() async throws {
        if startDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        try onStartCapture?()
        isStarted = true
    }

    func stopCapture() async throws -> AudioCaptureStopResult {
        isStarted = false
        return AudioCaptureStopResult(
            duration: duration,
            outputURL: outputURL,
            warnings: warnings,
            stoppedCapture: nil
        )
    }

    func setMicrophoneMuted(_ muted: Bool) {
        isMuted = muted
    }

    func currentMicrophoneState() -> MicrophoneRecordingState {
        return .receiving
    }
}

// MARK: - Application Service Tests

private final class FlatStoppedCapture: StoppedCaptureProtocol, @unchecked Sendable {
    let outputURL = URL(fileURLWithPath: "/unused")
    let duration = 15.0
    var finished = false
    func finish() async -> RecordingResult {
        finished = true
        return .init(outputURL: URL(fileURLWithPath: "/unused"), duration: 15, fileSize: 0, warnings: [])
    }
}

@Suite("Application Service Tests")
struct ApplicationServiceTests {

    @Test(arguments: [false, true], [false, true])
    func flatEnqueueRejectsBeforeAllWork(withRepository: Bool, stopped: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting_flat.m4a")
        for channel in ["host", "remote"] { try Data([1]).write(to: root.appendingPathComponent("raw/meeting_flat." + channel + "_record.wav")) }
        let runner = MockTranscriptionRunner(); runner.delayNanoseconds = 0
        let repo = withRepository ? RecordingHistoryRepository() : nil
        repo?.put(RecordingEntry.load(recording: url), persist: false)
        let capture = FlatStoppedCapture()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(), historyRepository: repo)
        let (events, continuation) = AsyncStream<ProcessingService.Event>.makeStream()
        await service.addEventHandler { continuation.yield($0) }
        await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false), stoppedCapture: stopped ? capture : nil)
        for await event in events {
            switch event {
            case .failed: continuation.finish()
            case .completed, .cancelled: Issue.record("Unsupported layout must fail before any processing"); continuation.finish()
            default: break
            }
        }
        #expect(runner.runCallCount == 0)
        #expect(!capture.finished)
        #expect(await service.totalJobCount == 0)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("raw/meeting_flat.processing.json").path))
    }

    @Test func flatApplicationStartRejectsBeforeCapture() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting_flat.m4a")
        let capture = MockAudioCaptureController(outputURL: url)
        let service = RecordingSessionService()
        await #expect(throws: Error.self) { try await service.start(controller: capture, outputURL: url) }
        #expect(!capture.isStarted)
        #expect(await service.currentSnapshot.phase == .idle)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @Test func standardStartBeforeRawAndLifecycleRetry() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting_before_raw")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting_before_raw.m4a")
        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("raw").path))
        let capture = MockAudioCaptureController(outputURL: url)
        capture.onStartCapture = { try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true) }
        _ = try await session.start(controller: capture, outputURL: url)
        #expect(capture.isStarted && repo.entry(url)?.phase == .recording)
        for channel in ["host", "remote"] {
            try Data([1, 2, 3]).write(to: root.appendingPathComponent("raw/meeting_before_raw." + channel + "_record.wav"))
        }
        _ = try await session.stop()
        #expect(RecordingEntry.load(recording: url).phase == .interrupted)
        #expect(repo.entry(url)?.capabilities.canRetry == true)
        let runner = MockTranscriptionRunner(); runner.delayNanoseconds = 0
        let processing = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(), historyRepository: repo)
        let (events, continuation) = AsyncStream<ProcessingService.Event>.makeStream()
        await processing.addEventHandler { continuation.yield($0) }
        await processing.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
        for await event in events {
            if case .completed = event { continuation.finish() }
        }
        #expect(runner.runCallCount == 1 && repo.entry(url)?.phase == .completed)
        for channel in ["host", "remote"] {
            #expect(try Data(contentsOf: root.appendingPathComponent("raw/meeting_before_raw." + channel + "_record.wav")) == Data([1, 2, 3]))
        }
    }

    @Test func testSettingsAreFixedAtEnqueueTime() async throws {
        let runner = MockTranscriptionRunner()
        let exporter = MockAudioExporter()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: exporter)

        let initialSettings = ProcessingJobSettings(parakeet: true, echoCancellation: true)
        let recordingURL = URL(fileURLWithPath: "/tmp/fake-recording/fake-recording.m4a")

        let (stream, continuation) = AsyncStream<ProcessingService.Event>.makeStream()
        await service.addEventHandler { event in
            continuation.yield(event)
        }

        await service.enqueue(recordingURL: recordingURL, settings: initialSettings)

        // Wait for completion
        for await event in stream {
            if case .completed = event {
                continuation.finish()
            }
        }

        // Verify the settings captured by the runner match the snapshot at enqueue time
        #expect(runner.capturedSettings?.parakeet == true)
        #expect(runner.capturedSettings?.echoCancellation == true)
    }

    @Test func testSingleSerialQueueExecutesJobsOneAtATime() async throws {
        let runner = MockTranscriptionRunner()
        runner.delayNanoseconds = 100_000_000 // 100ms per job
        let exporter = MockAudioExporter()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: exporter)

        let job1URL = URL(fileURLWithPath: "/tmp/recording1/recording1.m4a")
        let job2URL = URL(fileURLWithPath: "/tmp/recording2/recording2.m4a")
        let settings = ProcessingJobSettings(parakeet: false, echoCancellation: false)

        var eventsReceived: [String] = []
        let (stream, continuation) = AsyncStream<String>.makeStream()
        await service.addEventHandler { event in
            switch event {
            case .started(let job):
                continuation.yield("started:\(job.recordingURL.lastPathComponent)")
            case .completed(let job, _, _):
                continuation.yield("completed:\(job.recordingURL.lastPathComponent)")
            default:
                break
            }
        }

        await service.enqueue(recordingURL: job1URL, settings: settings)
        await service.enqueue(recordingURL: job2URL, settings: settings)

        var count = 0
        for await event in stream {
            eventsReceived.append(event)
            count += 1
            if count == 4 {
                continuation.finish()
            }
        }

        #expect(eventsReceived == [
            "started:recording1.m4a",
            "completed:recording1.m4a",
            "started:recording2.m4a",
            "completed:recording2.m4a"
        ])
    }

    @Test func testJobCancellationRemovesPendingJobAndEmitsCancelled() async throws {
        let runner = MockTranscriptionRunner()
        runner.delayNanoseconds = 200_000_000 // 200ms
        let exporter = MockAudioExporter()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: exporter)

        let job1URL = URL(fileURLWithPath: "/tmp/recording1/recording1.m4a")
        let job2URL = URL(fileURLWithPath: "/tmp/recording2/recording2.m4a")
        let settings = ProcessingJobSettings(parakeet: false, echoCancellation: false)

        let (stream, continuation) = AsyncStream<String>.makeStream()
        await service.addEventHandler { event in
            switch event {
            case .cancelled(let job, _):
                continuation.yield("cancelled:\(job.recordingURL.lastPathComponent)")
            case .completed(let job, _, _):
                continuation.yield("completed:\(job.recordingURL.lastPathComponent)")
            default:
                break
            }
        }

        await service.enqueue(recordingURL: job1URL, settings: settings)
        let job2 = await service.enqueue(recordingURL: job2URL, settings: settings)

        // Cancel job2 while job1 is still active
        await service.cancel(jobID: job2.id)

        var eventsReceived: [String] = []
        var count = 0
        for await event in stream {
            eventsReceived.append(event)
            count += 1
            if count == 2 {
                continuation.finish()
            }
        }

        #expect(eventsReceived.contains("cancelled:recording2.m4a"))
        #expect(eventsReceived.contains("completed:recording1.m4a"))
        #expect(runner.runCallCount == 1) // job2 was cancelled while queued, never ran
    }

    @Test func testConcurrentStartBarrierPreventsReentrancy() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)

        let file1 = tempDir.appendingPathComponent("rec1/rec1.m4a")
        let capture1 = MockAudioCaptureController(outputURL: file1)
        capture1.startDelayNanoseconds = 50_000_000 // 50ms to force concurrency overlap

        let file2 = tempDir.appendingPathComponent("rec2/rec2.m4a")
        let capture2 = MockAudioCaptureController(outputURL: file2)

        async let attempt1: Result<RecordingSessionSnapshot, Error> = {
            do {
                return .success(try await session.start(controller: capture1, outputURL: file1))
            } catch {
                return .failure(error)
            }
        }()

        async let attempt2: Result<RecordingSessionSnapshot, Error> = {
            do {
                return .success(try await session.start(controller: capture2, outputURL: file2))
            } catch {
                return .failure(error)
            }
        }()

        let (res1, res2) = await (attempt1, attempt2)

        let successes = [res1, res2].filter { if case .success = $0 { return true } else { return false } }
        let failures = [res1, res2].compactMap { res -> RecordingSessionService.ServiceError? in
            if case .failure(let err) = res, let serviceErr = err as? RecordingSessionService.ServiceError {
                return serviceErr
            }
            return nil
        }

        #expect(successes.count == 1)
        #expect(failures.count == 1)
        #expect(failures.first == .alreadyRecording)

        // Stop session
        let stopResult = try await session.stop(shortRecordingThreshold: 5.0)
        #expect(stopResult.wasCancelledShort == false)
        #expect(await session.isRecording == false)
    }

    @Test func testProcessingServicePreparationLifecycleAndBusyGuard() async throws {
        let runner = MockTranscriptionRunner()
        runner.delayNanoseconds = 100_000_000 // 100ms
        let exporter = MockAudioExporter()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: exporter)

        #expect(await service.isBusy == false)
        #expect(await service.currentPreparationState == .idle)

        async let prepTask = service.checkOrPrepareDependencies(prepare: true, parakeet: false)

        // Allow task to start
        try await Task.sleep(nanoseconds: 10_000_000)
        #expect(await service.isBusy == true)
        #expect(await service.currentPreparationState == .preparing)

        // Concurrent prep attempt must be rejected with busy error
        do {
            _ = try await service.checkOrPrepareDependencies(prepare: false, parakeet: false)
            Issue.record("Expected busy error")
        } catch {
            #expect(error.localizedDescription.contains("Сервис занят"))
        }

        let res = try await prepTask
        #expect(res.succeeded == true)
        #expect(await service.isBusy == false)
        #expect(await service.currentPreparationState == .idle)
    }

    @Test func testProcessingServiceRejectsRecordingWithoutOriginalSources() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let meetingFolder = tempDir.appendingPathComponent("meeting_20261103_000000")
        let rawFolder = meetingFolder.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)

        let m4aURL = meetingFolder.appendingPathComponent("meeting_20261103_000000.m4a")
        let transcriptURL = meetingFolder.appendingPathComponent("meeting_20261103_000000.sources.transcript.txt")
        try Data("audio".utf8).write(to: m4aURL)
        try Data("Existing recognized transcript".utf8).write(to: transcriptURL)

        let repo = RecordingHistoryRepository()
        let loaded = RecordingEntry.load(recording: m4aURL)
        #expect(loaded.isLegacy == true)
        repo.put(loaded)

        let runner = MockTranscriptionRunner()
        let exporter = MockAudioExporter()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: exporter, historyRepository: repo)

        let (stream, continuation) = AsyncStream<String>.makeStream()
        await service.addEventHandler { event in
            switch event {
            case .failed(let job, let err, _):
                continuation.yield("failed:\(job.recordingURL.lastPathComponent):\(err)")
            case .completed(let job, _, _):
                continuation.yield("completed:\(job.recordingURL.lastPathComponent)")
            default:
                break
            }
        }

        let job = await service.enqueue(
            recordingURL: m4aURL,
            settings: ProcessingJobSettings(parakeet: false, echoCancellation: false)
        )

        var failedMessage: String?
        for await msg in stream {
            failedMessage = msg
            continuation.finish()
        }

        #expect(failedMessage?.contains("Исходные WAV отсутствуют или недоступны") == true)
        #expect(runner.runCallCount == 0) // Never execute a runner without original sources
        _ = job
    }

    @Test func testShortRecordingCancellationCleansUpFiles() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)

        let meetingFolder = tempDir.appendingPathComponent("meeting_20261103_120000")
        try FileManager.default.createDirectory(at: meetingFolder, withIntermediateDirectories: true)
        let recURL = meetingFolder.appendingPathComponent("meeting_20261103_120000.m4a")
        try Data("audio data".utf8).write(to: recURL)

        let capture = MockAudioCaptureController(outputURL: recURL)
        capture.duration = 4.0 // under 10.0s threshold

        _ = try await session.start(controller: capture, outputURL: recURL)
        let stopResult = try await session.stop(shortRecordingThreshold: 10.0, trash: { url in
            try FileManager.default.removeItem(at: url)
        })

        #expect(stopResult.wasCancelledShort == true)
        #expect(FileManager.default.fileExists(atPath: meetingFolder.path) == false)
    }

    @Test func testConcurrentUpdatesPreserveBothFieldsInMemoryAndDisk() async throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let meetingFolder = tempDir.appendingPathComponent("meeting_20261103_000000")
        let rawFolder = meetingFolder.appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: rawFolder, withIntermediateDirectories: true)

        let m4aURL = meetingFolder.appendingPathComponent("meeting_20261103_000000.m4a")
        try Data("audio".utf8).write(to: m4aURL)

        var initial = RecordingEntry(recording: m4aURL, date: Date(), title: "Initial Title", phase: .completed)
        initial.duration = 10.0

        let repo = RecordingHistoryRepository()
        try repo.putThrowing(initial)

        await withTaskGroup(of: Void.self) { group in
            group.addTask {
                do {
                    _ = try repo.updateThrowing(m4aURL) { entry in
                        Thread.sleep(forTimeInterval: 0.02)
                        entry.title = "Updated Title"
                    }
                } catch {
                    Issue.record("Task 1 failed: \(error)")
                }
            }
            group.addTask {
                do {
                    _ = try repo.updateThrowing(m4aURL) { entry in
                        Thread.sleep(forTimeInterval: 0.02)
                        entry.duration = 42.0
                    }
                } catch {
                    Issue.record("Task 2 failed: \(error)")
                }
            }
        }

        // Check memory
        let inMemory = repo.entry(m4aURL)
        #expect(inMemory?.title == "Updated Title")
        #expect(inMemory?.duration == 42.0)

        // Check disk
        let onDisk = RecordingEntry.load(recording: m4aURL)
        #expect(onDisk.title == "Updated Title")
        #expect(onDisk.duration == 42.0)
    }

    @Test func testProcessingServicePreparationExcludesWorkerAndDrainsAfterCompletion() async throws {
        let runner = MockTranscriptionRunner()
        runner.delayNanoseconds = 10_000_000
        let exporter = MockAudioExporter()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: exporter)

        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            func wait() async {
                await withCheckedContinuation { cont in
                    continuation = cont
                }
            }
            func open() {
                continuation?.resume()
                continuation = nil
            }
        }

        let gate = Gate()
        let (prepStartedStream, prepStartedCont) = AsyncStream<Void>.makeStream()

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let recURL = tempDir.appendingPathComponent("rec/rec.m4a")
        try FileManager.default.createDirectory(at: recURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("audio".utf8).write(to: recURL)

        runner.onCheckDependencies = {
            prepStartedCont.yield(())
            await gate.wait()
        }

        let prepTask = Task {
            try await service.checkOrPrepareDependencies(
                prepare: true,
                parakeet: false
            )
        }

        for await _ in prepStartedStream {
            break
        }
        #expect(await service.currentPreparationState == .preparing)

        let (stream, continuation) = AsyncStream<String>.makeStream()
        await service.addEventHandler { event in
            switch event {
            case .started(let job):
                continuation.yield("started:\(job.recordingURL.lastPathComponent)")
            case .completed(let job, _, _):
                continuation.yield("completed:\(job.recordingURL.lastPathComponent)")
            default:
                break
            }
        }

        let job = await service.enqueue(
            recordingURL: recURL,
            settings: ProcessingJobSettings(parakeet: false, echoCancellation: false)
        )
        _ = job

        // Ensure that while preparing, worker is NOT started
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(runner.runCallCount == 0)
        #expect(await service.currentPreparationState == .preparing)

        // Release prep gate
        await gate.open()
        _ = try await prepTask.value

        // Worker should now drain and complete
        var events: [String] = []
        for await ev in stream {
            events.append(ev)
            if events.count == 2 {
                continuation.finish()
            }
        }

        #expect(events == ["started:rec.m4a", "completed:rec.m4a"])
        #expect(runner.runCallCount == 1)
        #expect(await service.currentPreparationState == .idle)
    }

    @Test func testRecordingEntryIsLegacyCanonicalNativeVsLegacyOnly() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let folder = tempDir.appendingPathComponent("meeting_20261103_000000")
        let rawFolder = folder.appendingPathComponent("raw")
        let transcriptsFolder = rawFolder.appendingPathComponent("transcripts")
        let resultFolder = transcriptsFolder.appendingPathComponent("res_valid_parakeet_off")
        try FileManager.default.createDirectory(at: resultFolder, withIntermediateDirectories: true)

        let m4aURL = folder.appendingPathComponent("meeting_20261103_000000.m4a")
        let txtURL = folder.appendingPathComponent("meeting_20261103_000000.sources.transcript.txt")
        let resultJSONURL = resultFolder.appendingPathComponent("result.json")

        try Data("audio".utf8).write(to: m4aURL)
        try Data("legacy text".utf8).write(to: txtURL)

        let fixtureURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("transcription/fixtures/transcript-document/valid_parakeet_off.json")
        try FileManager.default.copyItem(at: fixtureURL, to: resultJSONURL)

        let nativeEntry = RecordingEntry.load(recording: m4aURL)
        #expect(nativeEntry.isLegacy == false)

        try FileManager.default.removeItem(at: resultFolder)
        let legacyEntry = RecordingEntry.load(recording: m4aURL)
        #expect(legacyEntry.isLegacy == true)

        try FileManager.default.removeItem(at: txtURL)
        let emptyEntry = RecordingEntry.load(recording: m4aURL)
        #expect(emptyEntry.isLegacy == false)
    }
    @Test(arguments: [false, true]) func terminalMetadataFailureRemainsVisible(cancel: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting_terminal")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting_terminal.m4a")
        try Data([0, 0]).write(to: root.appendingPathComponent("raw/meeting_terminal").appendingPathExtension("host_record.wav"))
        try Data([0, 0]).write(to: root.appendingPathComponent("raw/meeting_terminal").appendingPathExtension("remote_record.wav"))
        let repo = RecordingHistoryRepository()
        let entry = RecordingEntry(recording: url, date: Date(), title: "Terminal", phase: .processing)
        try repo.putThrowing(entry)
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let runner = MockTranscriptionRunner()
        runner.onRun = {
            try Data("{broken".utf8).write(to: entry.metadata)
            readyContinuation.yield(())
            if cancel { try await Task.sleep(for: .seconds(30)) }
        }
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(), historyRepository: repo)
        let (events, continuation) = AsyncStream<ProcessingService.Event>.makeStream()
        await service.addEventHandler { continuation.yield($0) }
        let job = await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
        for await _ in ready { break }
        if cancel { await service.cancel(jobID: job.id) }
        var terminalWarning: String?
        for await event in events {
            switch event {
            case .completed(_, _, let warning), .cancelled(_, let warning):
                terminalWarning = warning
                continuation.finish()
            default: break
            }
        }
        #expect(terminalWarning != nil)
        #expect(repo.entry(url)?.persistenceWarning == terminalWarning)
        #expect(repo.entry(url)?.capabilities.canRetry == true)
        #expect(repo.entry(url)?.phase == (cancel ? .interrupted : .completed))
        #expect(repo.entry(url)?.phase.isWorking == false)
        #expect(await service.totalJobCount == 0)
        _ = await repo.refresh(root: root)
        #expect(repo.entry(url)?.phase == (cancel ? .interrupted : .completed))
        #expect(try Data(contentsOf: entry.metadata) == Data("{broken".utf8))
        runner.onRun = nil
        runner.delayNanoseconds = 0
        let (retryEvents, retryContinuation) = AsyncStream<ProcessingService.Event>.makeStream()
        await service.addEventHandler { retryContinuation.yield($0) }
        let retry = await service.enqueue(recordingURL: url, settings: .init(parakeet: true, echoCancellation: true))
        #expect(retry.id != job.id)
        for await event in retryEvents {
            if case .completed(let finished, _, _) = event {
                #expect(finished.id == retry.id)
                retryContinuation.finish()
            }
        }
        #expect(repo.entry(url)?.phase == .completed)
        #expect(await service.totalJobCount == 0)
        #expect(try Data(contentsOf: entry.metadata) == Data("{broken".utf8))
        for source in ["host", "remote"] {
            #expect(try Data(contentsOf: root.appendingPathComponent("raw/meeting_terminal").appendingPathExtension(source + "_record.wav")) == Data([0, 0]))
        }
    }

    @Test func newCapturePerservesUnknownMetadataWithoutFormatMarker() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting_versioned")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting_versioned.m4a")
        let metadata = root.appendingPathComponent("raw/meeting_versioned.processing.json")
        let unknown = "1234567890123456789012345678901234567890.1234567890123456789"
        try Data(("{\"unknownPrecision\":" + unknown + "}").utf8).write(to: metadata)
        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)
        _ = try await session.start(controller: MockAudioCaptureController(outputURL: url), outputURL: url)
        let entry = try #require(repo.entry(url))
        #expect(entry.phase == .recording)
        let bytes = try String(contentsOf: metadata, encoding: .utf8)
        #expect(bytes.contains(unknown))
        let json = try #require(try JSONSerialization.jsonObject(with: Data(bytes.utf8)) as? [String: Any])
        #expect(json["recordingFormatVersion"] == nil)
        _ = try await session.stop()
        #expect(RecordingEntry.load(recording: url).phase == .interrupted)
    }

    @Test func cancelledEditorAdmissionPreventsEnqueue() async throws {
        let runner = MockTranscriptionRunner()
        runner.delayNanoseconds = 0
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(),
            retryAdmission: { _ in false })
        let job = await service.enqueue(recordingURL: URL(fileURLWithPath: "/tmp/owned-admission-fixture/owned-admission-fixture.m4a"),
            settings: .init(parakeet: false, echoCancellation: false))
        for _ in 0..<100 { await Task.yield() }
        #expect(runner.runCallCount == 0)
        #expect(await service.totalJobCount == 0)
        #expect(await service.currentSnapshot().active?.id != job.id)
    }

}

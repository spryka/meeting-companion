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

private struct MockVoiceRunner: VoiceEmbeddingRunnerProtocol {
    var onModelCheck: @Sendable (Bool) async -> Void = { _ in }
    let onRun: @Sendable () async -> Void

    func checkOrPrepareVoiceModel(prepare: Bool) async throws { await onModelCheck(prepare) }

    func extractVoiceEmbeddings(
        _ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL
    ) async throws -> VoiceEmbeddingProtocol.Response {
        await onRun()
        return .init(requestID: request.id, features: request.windows.map {
            .init(windowID: $0.id, pcmFingerprint: $0.sourceFingerprint, embedding: nil)
        })
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
    var suspendStart: (@Sendable () async -> Void)?
    var suspendStop: (@Sendable () async -> Void)?
    var stopError = false
    var stoppedCapture: (any StoppedCaptureProtocol)?

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func startCapture() async throws {
        await suspendStart?()
        if startDelayNanoseconds > 0 {
            try await Task.sleep(nanoseconds: startDelayNanoseconds)
        }
        try onStartCapture?()
        isStarted = true
    }

    func stopCapture() async throws -> AudioCaptureStopResult {
        await suspendStop?()
        if stopError { throw NSError(domain: "SyntheticStop", code: 1) }
        isStarted = false
        return AudioCaptureStopResult(
            duration: duration,
            outputURL: outputURL,
            warnings: warnings,
            stoppedCapture: stoppedCapture
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
    private func voiceFixture() throws -> (root: URL, recording: URL, request: VoiceEmbeddingProtocol.Request) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent(UUID().uuidString)
        let recording = root.appendingPathComponent("meeting_voice/meeting_voice.m4a")
        try FileManager.default.createDirectory(
            at: recording.deletingLastPathComponent().appendingPathComponent("raw/transcripts/res_voice"),
            withIntermediateDirectories: true
        )
        try Data().write(to: recording)
        return (root, recording, .init(resultID: "res_voice", windows: [
            .init(sourceID: .host, sourceFingerprint: String(repeating: "a", count: 64), startFrame: 0, endFrame: 48_000)
        ]))
    }

    @Test(.timeLimit(.minutes(1))) func queuedASRStartsBeforeLearningOnTheSameLane() async throws {
        let (root, recording, request) = try voiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (log, trace) = AsyncStream<String>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish(); trace.finish() }
        let runner = MockTranscriptionRunner()
        runner.delayNanoseconds = 0
        runner.onRun = {
            trace.yield("asr")
            for await _ in gate {}
        }
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(),
                                        voiceRunner: MockVoiceRunner(onModelCheck: {
            #expect(!$0)
            trace.yield("check")
        }) { trace.yield("voice") })
        let settings = ProcessingJobSettings(parakeet: false, echoCancellation: false)
        let first = root.appendingPathComponent("first/first.m4a")
        let second = root.appendingPathComponent("second/second.m4a")
        for url in [first, second] {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        await service.addEventHandler { event in
            if case .failed(_, let reason, _) = event {
                trace.yield(reason)
                trace.finish()
            }
        }
        var activity = log.makeAsyncIterator()
        _ = await service.enqueue(recordingURL: first, settings: settings)
        #expect(await activity.next() == "asr")
        do {
            try await service.checkOrPrepareVoiceModel(prepare: false)
            #expect(await activity.next() == "check")
        } catch { Issue.record(error) }
        let updates = await service.observe()
        let voice = Task { try await service.extractVoiceEmbeddings(request, recordingURL: recording, kind: .learning) }
        for await update in updates {
            if case .snapshot(let snapshot) = update, snapshot.voiceJobCount == 1 { break }
        }
        #expect(await service.isProcessing(recordingURL: recording) == false)
        _ = await service.enqueue(recordingURL: second, settings: settings)
        release.finish()
        #expect(await activity.next() == "asr")
        #expect(await activity.next() == "voice")
        #expect(try await voice.value.requestID == request.id)
    }

    @Test(.timeLimit(.minutes(1)), arguments: [false, true])
    func voiceLateReplyIsRejectedAndDoesNotOwnASRState(cancel: Bool) async throws {
        let (root, recording, request) = try voiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (started, signal) = AsyncStream<Void>.makeStream()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { signal.finish(); release.finish() }
        let runner = MockVoiceRunner {
            signal.yield(())
            for await _ in gate {}
        }
        let service = ProcessingService(transcriptionRunner: MockTranscriptionRunner(), audioExporter: MockAudioExporter(),
                                        voiceRunner: runner)
        let task = Task { try await service.extractVoiceEmbeddings(request, recordingURL: recording, kind: .automaticAssignment) }
        var activity = started.makeAsyncIterator()
        _ = await activity.next()
        #expect(await service.isProcessing(recordingURL: recording) == false)
        #expect(await service.totalJobCount == 0)
        await #expect(throws: ProcessingService.VoiceJobError.duplicate) {
            try await service.extractVoiceEmbeddings(request, recordingURL: recording, kind: .automaticAssignment)
        }
        if cancel {
            task.cancel()
            release.finish()
            await #expect(throws: CancellationError.self) { try await task.value }
        } else {
            let result = recording.deletingLastPathComponent().appendingPathComponent("raw/transcripts/res_voice")
            try FileManager.default.moveItem(at: result, to: result.deletingLastPathComponent().appendingPathComponent("res_new"))
            release.finish()
            await #expect(throws: ProcessingService.VoiceJobError.staleResult) { try await task.value }
        }
        #expect(await service.hasPendingWork == false)
    }

    @Test(.timeLimit(.minutes(1))) func cancellingVoiceKeepsLaneUntilWorkerExits() async throws {
        let (root, recording, request) = try voiceFixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let (started, signal) = AsyncStream<CheckedContinuation<Void, Never>>.makeStream()
        defer { signal.finish() }
        let runner = MockVoiceRunner {
            await withCheckedContinuation { signal.yield($0) }
        }
        let processing = ProcessingService(transcriptionRunner: MockTranscriptionRunner(), audioExporter: MockAudioExporter(),
                                           voiceRunner: runner)
        let voice = Task { try await processing.extractVoiceEmbeddings(request, recordingURL: recording, kind: .learning) }
        var start = started.makeAsyncIterator()
        let gate = try #require(await start.next())
        var released = false
        defer { if !released { gate.resume() } }
        let asr = root.appendingPathComponent("asr/asr.m4a")
        try FileManager.default.createDirectory(at: asr.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: asr)
        let capture = RecordingSessionService()
        let controller = MockAudioCaptureController(outputURL: root.appendingPathComponent("capture/capture.m4a"))
        try FileManager.default.createDirectory(at: controller.outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await capture.start(controller: controller, outputURL: controller.outputURL)
        #expect(controller.isStarted)
        let asrJob = await processing.enqueue(recordingURL: asr, settings: .init(parakeet: false, echoCancellation: false))
        voice.cancel()
        let pending = await processing.currentSnapshot()
        #expect(pending.active == nil)
        #expect(pending.queued.map(\.id) == [asrJob.id])
        released = true
        gate.resume()
        await #expect(throws: CancellationError.self) { try await voice.value }
        let events = await processing.observe()
        for await event in events {
            if case .snapshot(let snapshot) = event, snapshot.jobCount == 0 { break }
        }
        #expect(controller.isStarted)
        _ = try await capture.stop(expectedSessionID: (await capture.currentSnapshot).sessionID)
    }


    @Test func queuedProgressWaitsForActualAudioStart() async throws {
        let runner = QueuedProgressRunner()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter())
        let updates = await service.observe()
        let a = URL(fileURLWithPath: "/synthetic/a/a.m4a"), b = URL(fileURLWithPath: "/synthetic/b/b.m4a")
        _ = await service.enqueue(recordingURL: a, settings: .init(parakeet: false, echoCancellation: false))
        for _ in 0..<1000 { if await runner.waiting(a) { break }; try await Task.sleep(for: .milliseconds(1)) }
        try #require(await runner.waiting(a))
        let second = await service.enqueue(recordingURL: b, settings: .init(parakeet: true, echoCancellation: true))
        var iterator = updates.makeAsyncIterator()
        while let update = await iterator.next() {
            guard case .snapshot(let value) = update, value.queued.contains(where: { $0.id == second.id }),
                  let queued = value.routes[b] else { continue }
            #expect(queued.route.count == 6 && queued.jobID == second.id)
            #expect(queued.current == nil, "Queued B has no current station before any actual start")
            #expect(!queued.states.values.contains(.current))
            #expect(queued.local == nil && queued.localFraction == nil)
            #expect(queued.countText == "В очереди · 6 этапов", "Capsule/details must report waiting")
            break
        }
        await runner.finish(a)
        var sawActualStart = false
        while let update = await iterator.next() {
            guard case .snapshot(let value) = update, let started = value.routes[b],
                  started.local?.stage == .audio, started.local?.state == .started else { continue }
            #expect(value.active?.id == second.id)
            #expect(started.current == .audio && started.states[.audio] == .current)
            #expect(started.countText == "Этап 1 из 6")
            sawActualStart = true
            break
        }
        #expect(sawActualStart)
        for _ in 0..<1000 { if await runner.waiting(b) { break }; try await Task.sleep(for: .milliseconds(1)) }
        try #require(await runner.waiting(b))
        await runner.finish(b)
    }

    @Test func processingRouteFrozenSourcesAndIdentity() {
        for (aec, parakeet, count) in [(false, false, 4), (true, false, 5), (false, true, 5), (true, true, 6)] {
            let job = ProcessingJob(recordingURL: URL(fileURLWithPath: "/synthetic/a/a.m4a"), settings: .init(parakeet: parakeet, echoCancellation: aec))
            var snapshot = ProcessingProgressSnapshot(job: job)
            #expect(snapshot.route.count == count)
            #expect(snapshot.countText == "В очереди · \(count) этапов")
            snapshot.receive(.init(stage: .merge, completed: 0, total: 0), jobID: UUID())
            #expect(snapshot.current == nil)
            snapshot.receive(.init(stage: .diarization, channel: "host", completed: 1, total: 1), jobID: job.id)
            #expect(snapshot.states[.diarization] != .completed)
            snapshot.receive(.init(stage: .diarization, channel: "remote", completed: 1, total: 1), jobID: job.id)
            #expect(snapshot.states[.diarization] == .completed)
        }
    }

    @Test func processingRouteIncludesVoicesWhenVoiceMatchPolicyEnabled() throws {
        let policy = try #require(VoiceMatchPolicy(threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        for (aec, parakeet, baseCount) in [(false, false, 4), (true, false, 5), (false, true, 5), (true, true, 6)] {
            let settings = ProcessingJobSettings(parakeet: parakeet, echoCancellation: aec, voiceMatchPolicy: policy)
            #expect(settings.voiceIdentification)
            let job = ProcessingJob(recordingURL: URL(fileURLWithPath: "/synthetic/a/a.m4a"), settings: settings)
            var snapshot = ProcessingProgressSnapshot(job: job)
            let total = baseCount + 1
            #expect(snapshot.route.count == total)
            #expect(snapshot.route.last == .voices)
            #expect(ProcessingProgressSnapshot.Station.voices.title == "Определение голосов")
            #expect(ProcessingProgressSnapshot.Station.voices.model == "WeSpeaker")
            #expect(snapshot.countText == "В очереди · \(total) этапов")
            snapshot.receive(.init(stage: .publication, completed: 0, total: 1), jobID: job.id)
            #expect(snapshot.states[.saving] == .current)
            snapshot.receive(.init(stage: .voices, completed: 0, total: 0, state: .started), jobID: job.id)
            #expect(snapshot.states[.saving] == .completed)
            #expect(snapshot.current == .voices)
            #expect(snapshot.states[.voices] == .current)
            #expect(snapshot.countText == "Этап \(total) из \(total)")
        }
    }

    @Test func nemotronCompletionIncludesSpeechWindowDiagnostics() {
        let job = ProcessingJob(recordingURL: URL(fileURLWithPath: "/synthetic/a/a.m4a"), settings: .init(parakeet: false, echoCancellation: false))
        var snapshot = ProcessingProgressSnapshot(job: job)
        #expect(snapshot.route.map(\.rawValue) == ["audio", "diarization", "recognition", "saving"])
        #expect(ProcessingProgressSnapshot.Station.diarization.model == "Nemotron")
        snapshot.receive(.init(stage: .diarization, channel: "host", completed: 0, total: 0, state: .completed), jobID: job.id)
        #expect(snapshot.states[.diarization] == .current)
        let warning = "Нет интервалов речи Nemotron; распознаются все окна."
        snapshot.receive(.init(stage: .diarization, channel: "remote", completed: 0, total: 0, warning: warning, state: .failed), jobID: job.id)
        #expect(snapshot.states[.diarization] == .failed)
        #expect(snapshot.localFraction == nil && snapshot.route.count == 4)
        #expect(snapshot.reasons[.diarization] == warning)
        snapshot.receive(.init(stage: .gigaam, channel: "host", completed: 0, total: 1), jobID: job.id)
        #expect(snapshot.countText == "Этап 3 из 4")
        #expect(snapshot.warnings.contains(warning))
    }

    @Test func processingLocalTruthAndSavingAcceptance() {
        let job = ProcessingJob(recordingURL: URL(fileURLWithPath: "/synthetic/a/a.m4a"), settings: .init(parakeet: true, echoCancellation: true))
        var snapshot = ProcessingProgressSnapshot(job: job)
        snapshot.receive(.init(stage: .audio, completed: 0, total: 0, state: .completed), jobID: job.id)
        snapshot.receive(.init(stage: .echo, channel: "host", completed: 80, total: 100), jobID: job.id)
        #expect(snapshot.localFraction == 0.8)
        snapshot.receive(.init(stage: .echo, channel: "host", completed: 0, total: 0, state: .completed), jobID: job.id)
        #expect(snapshot.states[.echo] == .completed, "AEC is common/host-only")
        snapshot.receive(.init(stage: .diarization, channel: "host", completed: 0, total: 1), jobID: job.id)
        #expect(snapshot.localFraction == nil, "Start/end sentinel is not measured work")
        for source in ["host", "remote"] {
            snapshot.receive(.init(stage: .diarization, channel: source, completed: 0, total: 0, warning: "Synthetic speech intervals unavailable", state: .skipped), jobID: job.id)
        }
        #expect(snapshot.states[.diarization] == .skipped && snapshot.reasons[.diarization] == "Synthetic speech intervals unavailable")
        snapshot.receive(.init(stage: .gigaam, channel: "host", completed: 1, total: 1), jobID: job.id)
        #expect(snapshot.localFraction == 1 && snapshot.states[.recognition] == .current)
        #expect(snapshot.currentIndex == 3 && snapshot.countText == "Этап 4 из 6")
        snapshot.receive(.init(stage: .speakers, channel: "host", completed: 0, total: 0, state: .completed), jobID: job.id)
        #expect(snapshot.states[.recognition] == .current)
        snapshot.receive(.init(stage: .gigaam, channel: "remote", completed: 0, total: 0), jobID: job.id)
        #expect(snapshot.localFraction == nil && snapshot.currentIndex == 3)
        snapshot.receive(.init(stage: .speakers, channel: "remote", completed: 0, total: 0, state: .completed), jobID: job.id)
        #expect(snapshot.states[.recognition] == .completed)
        snapshot.receive(.init(stage: .parakeet, channel: "remote", completed: 4, total: 4), jobID: job.id)
        #expect(snapshot.states[.correction] == .current, "Cascade has not finished")
        snapshot.receive(.init(stage: .publication, completed: 1, total: 1, state: .completed), jobID: job.id)
        #expect(snapshot.countText == "Этап 6 из 6")
        #expect(snapshot.states[.saving] == .current && !snapshot.terminal && snapshot.localFraction == nil)
        snapshot.finish(success: false, reason: "Synthetic publication rejected")
        #expect(snapshot.states[.saving] == .failed && snapshot.failure == "Synthetic publication rejected")
        let terminal = snapshot
        snapshot.receive(.init(stage: .gigaam, completed: 2, total: 3), jobID: job.id)
        #expect(snapshot == terminal)
    }

    @Test func processingServiceDrainsOrderedProgressBeforeAcceptedResult() async throws {
        let runner = OrderedProgressRunner()
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter())
        let updates = await service.observe()
        let url = URL(fileURLWithPath: "/synthetic/a/a.m4a")
        let job = await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
        var delivered: [Int] = []
        var sawHostOnly = false
        for await update in updates {
            switch update {
            case .event(.progress(_, let event)) where event.stage == .gigaam:
                delivered.append(event.completed)
            case .snapshot(let value):
                guard let route = value.routes[url] else { continue }
                if route.sources[.recognition] == Set(["host"]) {
                    sawHostOnly = true
                    #expect(route.states[.recognition] == .current)
                }
                if route.terminal {
                    #expect(route.jobID == job.id && route.route.count == 4)
                    #expect(route.states[.recognition] == .completed && route.states[.saving] == .warning)
                    #expect(delivered == Array(0...100), "No callback reordering or terminal loss")
                    #expect(sawHostOnly && route.warnings.contains("Synthetic committed warning"))
                    return
                }
            default: break
            }
        }
        Issue.record("Service observation ended without accepted terminal snapshot")
    }

    private func makeInlineVoiceRecording(
        resultID: String = "res_inline",
        olderResultID: String? = nil
    ) throws -> (root: URL, folder: URL, recording: URL, catalogue: VoiceProfileCatalogueRepository, alice: VoiceProfilePerson) {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("inline-voice-" + UUID().uuidString)
        let folder = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        let recording = folder.appendingPathComponent("meeting.m4a")
        for name in ["meeting.m4a", "raw/meeting.host_record.wav", "raw/meeting.remote_record.wav"] {
            try Data([0, 0]).write(to: folder.appendingPathComponent(name))
        }
        let catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: root.appendingPathComponent("appData"))
        let alice = VoiceProfilePerson(displayName: "Алиса")
        let bob = VoiceProfilePerson(displayName: "Боб")
        _ = try catalogue.update(catalogue.load()) { value in
            let vAlice: [Float] = [1] + Array(repeating: 0, count: 255)
            let vBob: [Float] = [0, 1] + Array(repeating: 0, count: 254)
            value.people = [alice, bob]
            value.samples = zip([alice, bob], [vAlice, vBob]).map { person, vector in
                .init(personID: person.id, embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID, embedding: vector,
                      recordingLocator: "/synthetic/seed", resultID: "seed", turnID: "seed",
                      sourceID: .host, start: 0, end: 5, pcmFingerprint: person.id.uuidString,
                      assignment: .init(personID: person.id, origin: "manual"), policyID: "test")
            }
            value.aggregates = value.samples.map {
                .init(personID: $0.personID, embeddingSpaceID: $0.embeddingSpaceID, centroid: $0.embedding,
                      activeSampleIDs: [$0.id], policyID: "test")
            }
        }
        if let olderResultID {
            try writeInlineVoiceResult(resultID: olderResultID, in: folder, createdAt: Date(timeIntervalSince1970: 100))
        }
        return (root, folder, recording, catalogue, alice)
    }

    private func writeInlineVoiceResult(resultID: String, in folder: URL, createdAt: Date) throws {
        let fixtureURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_empty_voices.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixtureURL)) as? [String: Any])
        json["resultID"] = resultID
        if var playback = json["playback"] as? [String: Any] {
            playback["mixPath"] = "raw/transcripts/" + resultID + "/mix.m4a"
            json["playback"] = playback
        }
        for key in ["words", "baselineWords", "turns"] {
            var items = try #require(json[key] as? [[String: Any]])
            items[0]["end"] = 5.0
            json[key] = items
        }
        let resultDir = folder.appendingPathComponent("raw/transcripts/" + resultID)
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        let resultFile = resultDir.appendingPathComponent("result.json")
        try JSONSerialization.data(withJSONObject: json).write(to: resultFile)
        try Data("00:00 [Собеседник 1] Монолог\n".utf8).write(to: resultDir.appendingPathComponent("transcript.txt"))
        let doc = try TranscriptDocument.load(from: resultFile, recordingDirectory: folder)
        let host = try #require(doc.sources.first { $0.id == .host })
        let remote = try #require(doc.sources.first { $0.id == .remote })
        let quality = VoiceAudioQuality(resultID: resultID, producer: "test", sources: [
            .init(id: .host, recognitionAudioPath: host.recognitionAudioPath,
                  fingerprint: String(repeating: "a", count: 64), duration: 5,
                  speech: [.init(start: 0, end: 5)], overlap: []),
            .init(id: .remote, recognitionAudioPath: remote.recognitionAudioPath,
                  fingerprint: String(repeating: "b", count: 64), duration: 5,
                  speech: nil, overlap: [])
        ], recordingFingerprint: String(repeating: "c", count: 64))
        try quality.encoded(for: doc).write(to: resultDir.appendingPathComponent(VoiceAudioQuality.filename))
        try FileManager.default.setAttributes([.creationDate: createdAt], ofItemAtPath: resultDir.path)
    }

    @Test(.timeLimit(.minutes(1)))
    func inlineVoiceAssignmentBlocksCompletionUntilAutoNamesSaved() async throws {
        let fx = try makeInlineVoiceRecording()
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: fx.catalogue)
        coordinator.setEnabled(true)
        coordinator.reconcileLibrary(recordings: [], scanComplete: true, id: coordinator.beginLibraryReconciliation())
        let policy = try #require(VoiceMatchPolicy(threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))

        let (voiceEntered, signalEntered) = AsyncStream<Void>.makeStream()
        let (voiceGate, openVoiceGate) = AsyncStream<Void>.makeStream()
        defer { signalEntered.finish(); openVoiceGate.finish() }

        let asrRunner = InlineVoiceASRRunner {
            try self.writeInlineVoiceResult(resultID: "res_inline", in: fx.folder, createdAt: Date())
            return fx.folder.appendingPathComponent("raw/transcripts/res_inline/transcript.txt")
        }
        let voiceRunner = InlineVoiceEmbeddingRunner { request in
            signalEntered.yield(())
            for await _ in voiceGate {}
            let vAlice: [Float] = [1] + Array(repeating: 0, count: 255)
            return .init(requestID: request.id, features: request.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vAlice)
            })
        }
        let repo = RecordingHistoryRepository(voiceLearning: coordinator)
        try repo.putThrowing(RecordingEntry.load(recording: fx.recording))
        let service = ProcessingService(
            transcriptionRunner: asrRunner,
            audioExporter: MockAudioExporter(),
            historyRepository: repo,
            voiceLearning: coordinator,
            voiceRunner: voiceRunner
        )
        let updates = await service.observe()
        let job = await service.enqueue(
            recordingURL: fx.recording,
            settings: .init(parakeet: false, echoCancellation: false,
                            voiceMatchPolicy: policy, voiceFeatureGeneration: coordinator.featureGeneration)
        )

        var entered = voiceEntered.makeAsyncIterator()
        _ = await entered.next()

        var sawBlockedInVoices = false
        for await update in updates {
            if case .snapshot(let snap) = update, let route = snap.routes[fx.recording], route.current == .voices {
                #expect(route.jobID == job.id && route.route.count == 5 && !route.terminal)
                #expect(route.states[.saving] == .completed)
                #expect(await service.isProcessing(recordingURL: fx.recording))
                #expect(repo.entry(fx.recording)?.phase == .processing)
                #expect(try !TranscriptEditsRepository(recordingDirectory: fx.folder).hasStoredEdits(resultID: "res_inline"))
                sawBlockedInVoices = true
                break
            }
        }
        #expect(sawBlockedInVoices)

        openVoiceGate.finish()
        var finished = false
        for await update in updates {
            if case .snapshot(let snap) = update, let route = snap.routes[fx.recording], route.terminal {
                #expect(route.states[.voices] == .completed && route.failure == nil)
                finished = true
                break
            }
        }
        #expect(finished)
        #expect(repo.entry(fx.recording)?.phase == .completed)
        #expect(!(await service.isProcessing(recordingURL: fx.recording)))
        let edits = try TranscriptEditsRepository(recordingDirectory: fx.folder).loadEdits(resultID: "res_inline")
        #expect(edits.overrides["turn_1"]?.displayName == fx.alice.displayName)
        #expect(edits.overrides["turn_1"]?.assignment?.origin == "automaticVoiceMatch")
    }

    @Test(.timeLimit(.minutes(1)), arguments: ["workerError", "insufficientProfiles", "noCatalogue", "featureDisabledMidStage", "cancelledMidStage", "retryWithHeldWriteLock"])
    func inlineVoiceAssignmentDegradesSafelyAndSupportsRetryLock(scenario: String) async throws {
        let older = scenario == "retryWithHeldWriteLock" ? "res_old" : nil
        let fx = try makeInlineVoiceRecording(olderResultID: older)
        defer { try? FileManager.default.removeItem(at: fx.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: fx.catalogue)
        coordinator.setEnabled(true)
        coordinator.reconcileLibrary(recordings: [], scanComplete: true, id: coordinator.beginLibraryReconciliation())
        if scenario == "insufficientProfiles" {
            let people = try fx.catalogue.load().catalogue.people
            try coordinator.resetPerson(people[1].id, delete: true)
        } else if scenario == "noCatalogue" {
            try FileManager.default.removeItem(at: fx.catalogue.directory)
        }
        let policy = try #require(VoiceMatchPolicy(threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))

        let (voiceEntered, signalEntered) = AsyncStream<Void>.makeStream()
        let (voiceGate, openVoiceGate) = AsyncStream<Void>.makeStream()
        defer { signalEntered.finish(); openVoiceGate.finish() }
        let workerCalls = AsyncStream<Void>.makeStream()
        workerCalls.continuation.finish()

        let callCounter = BoxedCounter()
        let asrRunner = InlineVoiceASRRunner {
            try self.writeInlineVoiceResult(resultID: "res_new", in: fx.folder, createdAt: Date().addingTimeInterval(60))
            return fx.folder.appendingPathComponent("raw/transcripts/res_new/transcript.txt")
        }
        let voiceRunner = InlineVoiceEmbeddingRunner { request in
            callCounter.increment()
            if scenario == "workerError" {
                throw NSError(domain: "InlineVoiceTest", code: 7, userInfo: [NSLocalizedDescriptionKey: "Worker offline"])
            }
            if scenario == "featureDisabledMidStage" || scenario == "cancelledMidStage" {
                signalEntered.yield(())
                for await _ in voiceGate {}
            }
            let vAlice: [Float] = [1] + Array(repeating: 0, count: 255)
            return .init(requestID: request.id, features: request.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vAlice)
            })
        }
        let repo = RecordingHistoryRepository(voiceLearning: coordinator)
        var initialEntry = RecordingEntry.load(recording: fx.recording)
        if older != nil { initialEntry.phase = .completed }
        try repo.putThrowing(initialEntry)
        let service = ProcessingService(
            transcriptionRunner: asrRunner,
            audioExporter: MockAudioExporter(),
            historyRepository: repo,
            voiceLearning: coordinator,
            voiceRunner: voiceRunner
        )
        let updates = await service.observe()
        let job = await service.enqueue(
            recordingURL: fx.recording,
            settings: .init(parakeet: false, echoCancellation: false,
                            voiceMatchPolicy: policy, voiceFeatureGeneration: coordinator.featureGeneration)
        )

        if scenario == "featureDisabledMidStage" || scenario == "cancelledMidStage" {
            var it = voiceEntered.makeAsyncIterator()
            _ = await it.next()
            if scenario == "featureDisabledMidStage" {
                coordinator.setEnabled(false)
                await service.cancelVoiceJobsIfDisabled()
            } else {
                await service.cancel(jobID: job.id)
            }
            openVoiceGate.finish()
        }

        var terminalRoute: ProcessingProgressSnapshot?
        for await update in updates {
            if case .snapshot(let snap) = update, let route = snap.routes[fx.recording], route.terminal {
                terminalRoute = route
                break
            }
        }
        let route = try #require(terminalRoute)
        let entry = try #require(repo.entry(fx.recording))
        #expect(entry.phase == .completed)
        #expect(route.failure == nil)
        #expect(route.states[.saving] == .completed)
        #expect(entry.problems.filter(\.isError).isEmpty)

        let edits = try TranscriptEditsRepository(recordingDirectory: fx.folder).loadEdits(resultID: "res_new")
        switch scenario {
        case "workerError":
            #expect(route.states[.voices] == .failed)
            #expect(route.warnings.contains { $0.contains("Автоопределение голосов не выполнено") })
        case "insufficientProfiles", "noCatalogue":
            #expect(callCounter.value == 0)
            #expect(route.states[.voices] == .skipped)
            #expect(route.reasons[.voices]?.contains("профил") == true)
            #expect(route.warnings.isEmpty)
            #expect(entry.problems.isEmpty)
            #expect(edits.overrides["turn_1"]?.voiceRefusal == .insufficientProfiles)
            if scenario == "noCatalogue" {
                #expect(!FileManager.default.fileExists(atPath: fx.catalogue.directory.path))
            }
        case "featureDisabledMidStage":
            #expect(route.states[.voices] == .skipped)
            #expect(route.reasons[.voices]?.contains("выключено") == true)
            #expect(route.warnings.isEmpty)
            #expect(entry.problems.isEmpty)
            #expect(edits.overrides["turn_1"]?.displayName == nil)
        case "cancelledMidStage":
            let warning = "Новый результат сохранён до отмены определения голосов."
            #expect(route.states[.voices] == .skipped)
            #expect(route.warnings == [warning])
            #expect(entry.problems.map(\.message) == [warning])
            #expect(edits.overrides["turn_1"]?.displayName == nil)
        case "retryWithHeldWriteLock":
            #expect(route.states[.voices] == .completed)
            #expect(edits.overrides["turn_1"]?.displayName == fx.alice.displayName)
            #expect(edits.overrides["turn_1"]?.assignment?.origin == "automaticVoiceMatch")
            let lockCheck = TranscriptEditsRepository(recordingDirectory: fx.folder)
            try lockCheck.acquireWriteLock()
            lockCheck.releaseWriteLock()
        default: Issue.record("Unexpected scenario")
        }
    }

    @Test func handoffMissingIdentityCannotMutateSuccessor() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        func output(_ name: String) throws -> URL {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            return folder.appendingPathComponent(name + ".m4a")
        }
        let service = RecordingSessionService(historyRepo: RecordingHistoryRepository())
        let a = MockAudioCaptureController(outputURL: try output("a"))
        let first = try await service.start(controller: a, outputURL: a.outputURL)
        _ = try await service.stop(elapsed: 15, expectedSessionID: first.sessionID)
        let b = MockAudioCaptureController(outputURL: try output("b"))
        let second = try await service.start(controller: b, outputURL: b.outputURL)
        await service.setMicrophoneMuted(true)
        #expect(!b.isMuted, "Missing mute identity must not select successor B")
        var rejected = false
        do { _ = try await service.stop(elapsed: 15) } catch { rejected = true }
        #expect(rejected, "Missing stop identity must be rejected")
        #expect(b.isStarted)
        #expect(await service.currentSnapshot.sessionID == second.sessionID)
        if await service.isRecording {
            _ = try await service.stop(elapsed: 15, expectedSessionID: second.sessionID)
        }
    }

    @Test func handoffOrdinaryStopNeverDeletesShortCapture() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting_short")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder.deletingLastPathComponent()) }
        let url = folder.appendingPathComponent("meeting_short.m4a")
        try Data("synthetic original".utf8).write(to: url)
        let capture = MockAudioCaptureController(outputURL: url)
        capture.duration = 9
        let service = RecordingSessionService(historyRepo: RecordingHistoryRepository())
        let started = try await service.start(controller: capture, outputURL: url)
        let stopped = try await service.stop(elapsed: 9, expectedSessionID: started.sessionID, trash: { _ in })
        #expect(!stopped.wasCancelledShort, "Only explicit short cancellation may discard capture")
        #expect(try Data(contentsOf: url) == Data("synthetic original".utf8))
    }

    @Test func workspaceRenameExcludesSuspendedCaptureAndAdmission() async throws {
        actor Gate {
            var continuation: CheckedContinuation<Void, Never>?
            let entered: AsyncStream<Void>.Continuation
            init(_ entered: AsyncStream<Void>.Continuation) { self.entered = entered }
            func wait() async { await withCheckedContinuation { continuation = $0; entered.yield(()) } }
            func open() { continuation?.resume(); continuation = nil }
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("meeting_test")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("meeting_test.m4a")
        let repo = RecordingHistoryRepository()
        _ = try repo.putThrowing(RecordingEntry(recording: url, date: Date(), title: "Original", phase: .completed))
        let capture = MockAudioCaptureController(outputURL: url)
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let gate = Gate(continuation)
        capture.suspendStart = { await gate.wait() }
        let session = RecordingSessionService(historyRepo: repo)
        let start = Task { try await session.start(controller: capture, outputURL: url) }
        var iterator = entered.makeAsyncIterator(); _ = await iterator.next()
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "During starting") }
        await gate.open(); _ = try await start.value
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "During capture") }
        capture.suspendStop = { await gate.wait() }
        let stop = Task { try await session.stop(elapsed: 15, expectedSessionID: (await session.currentSnapshot).sessionID) }
        _ = await iterator.next()
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "During saving") }
        await gate.open(); _ = try await stop.value
        _ = try repo.rename(url, displayTitle: "After stop")
        let runner = MockTranscriptionRunner(); runner.delayNanoseconds = 0
        let processing = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(), historyRepository: repo,
            retryAdmission: { _ in await gate.wait(); return false })
        let pending = Task { await processing.enqueue(recordingURL: url, settings: ProcessingJobSettings(parakeet: false, echoCancellation: false)) }
        _ = await iterator.next()
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "During admission") }
        await gate.open(); _ = await pending.value
        _ = try repo.rename(url, displayTitle: "After admission")
    }

    @Test func trashReservationRejectsCaptureAndEnqueueBeforeSideEffects() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("meeting_trash")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("meeting_trash.m4a")
        let repo = RecordingHistoryRepository()
        _ = try repo.putThrowing(RecordingEntry(recording: url, date: Date(), title: "Original", phase: .completed))
        let target = try repo.prepareTrash(url, root: root), token = try repo.reserveTrash(target)
        defer { repo.releaseTrash(target, id: token) }
        let capture = MockAudioCaptureController(outputURL: url)
        let session = RecordingSessionService(historyRepo: repo)
        await #expect(throws: Error.self) { try await session.start(controller: capture, outputURL: url) }
        #expect(!capture.isStarted)
        let runner = MockTranscriptionRunner(); runner.delayNanoseconds = 0
        let processing = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(), historyRepository: repo,
            retryAdmission: { _ in Issue.record("Trash must exclude retry admission before any await"); return true })
        _ = await processing.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false))
        #expect(await processing.totalJobCount == 0)
        #expect(runner.runCallCount == 0)
        #expect(repo.entry(url)?.phase == .completed)
    }

    @Test func workspaceRenameExcludesPendingCaptureFinalization() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("meeting_pending")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("meeting_pending.m4a")
        let repo = RecordingHistoryRepository()
        let capture = MockAudioCaptureController(outputURL: url)
        capture.stoppedCapture = FlatStoppedCapture()
        let session = RecordingSessionService(historyRepo: repo)
        _ = try await session.start(controller: capture, outputURL: url)
        let stopped = try await session.stop(elapsed: 15, expectedSessionID: (await session.currentSnapshot).sessionID)
        #expect(stopped.stoppedCapture != nil)
        #expect(repo.entry(url)?.phase == .saving)
        #expect(throws: Error.self) { try repo.rename(url, displayTitle: "Before enqueue") }
    }

    @Test func workspaceRenameExcludesQueuedAndActiveUntilCancelTeardown() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = RecordingHistoryRepository()
        var urls: [URL] = []
        for name in ["active", "queued", "unrelated"] {
            let folder = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
            let url = folder.appendingPathComponent(name + ".m4a")
            for source in ["host", "remote"] {
                try Data([0, 0]).write(to: folder.appendingPathComponent("raw/" + name + "." + source + "_record.wav"))
            }
            _ = try repo.putThrowing(RecordingEntry.load(recording: url))
            urls.append(url)
        }
        let runner = MockTranscriptionRunner()
        let (started, continuation) = AsyncStream<Void>.makeStream()
        runner.onRun = { continuation.yield(()); try await Task.sleep(for: .seconds(30)) }
        let processing = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(), historyRepository: repo)
        let settings = ProcessingJobSettings(parakeet: false, echoCancellation: false)
        let active = await processing.enqueue(recordingURL: urls[0], settings: settings)
        for await _ in started { break }
        let queued = await processing.enqueue(recordingURL: urls[1], settings: settings)
        #expect(throws: Error.self) { try repo.rename(urls[0], displayTitle: "Active") }
        #expect(throws: Error.self) { try repo.rename(urls[1], displayTitle: "Queued") }
        _ = try repo.rename(urls[2], displayTitle: "Unrelated remains editable")
        await processing.cancel(jobID: queued.id)
        _ = try repo.rename(urls[1], displayTitle: "After queued cancellation")
        await processing.cancel(jobID: active.id)
        #expect(await processing.totalJobCount == 0)
        _ = try repo.rename(urls[0], displayTitle: "After active teardown")
    }

    @Test func workspaceRenameReservationsReleaseOnCaptureFailures() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("meeting_test")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = folder.appendingPathComponent("meeting_test.m4a")
        let repo = RecordingHistoryRepository()
        _ = try repo.putThrowing(RecordingEntry(recording: url, date: Date(), title: "Original", phase: .completed))
        let capture = MockAudioCaptureController(outputURL: url)
        capture.onStartCapture = { throw NSError(domain: "SyntheticStart", code: 1) }
        let session = RecordingSessionService(historyRepo: repo)
        await #expect(throws: Error.self) { try await session.start(controller: capture, outputURL: url) }
        _ = try repo.rename(url, displayTitle: "After failed start")
        capture.onStartCapture = nil
        _ = try await session.start(controller: capture, outputURL: url)
        capture.stopError = true
        await #expect(throws: Error.self) { try await session.stop(elapsed: 15, expectedSessionID: (await session.currentSnapshot).sessionID) }
        _ = try repo.rename(url, displayTitle: "After failed stop")
    }

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
        _ = try await session.stop(expectedSessionID: (await session.currentSnapshot).sessionID)
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

    @Test func retryPreservesPendingVoiceEventsBeforeStartingTheWorker() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("meeting")
        let recording = directory.appendingPathComponent("meeting.m4a")
        let resultID = "res_valid_empty_voices"
        let writer = TranscriptEditsRepository(recordingDirectory: directory, learningCommitObserver: { _, _ in })
        let result = writer.resultURL(for: resultID)
        try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_empty_voices.json")
        try FileManager.default.copyItem(at: fixture, to: result)
        try Data().write(to: recording)
        for channel in ["host", "remote"] {
            try Data([1, 2, 3]).write(to: directory.appendingPathComponent("raw/meeting." + channel + "_record.wav"))
        }
        let profiles = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
        let coordinator = VoiceLearningCoordinator(catalogue: profiles)
        let choice = try coordinator.personSelection(.new(UUID()), displayName: "Анна")
        let assignments = TranscriptSpeakerAssignmentService(editsRepository: writer)
        let preview = try assignments.previewAssignment(resultID: resultID, anchorTurnID: "turn_1", scope: .single,
            displayName: "Анна", person: choice)
        _ = try assignments.assignSpeakerName(preview: preview, displayName: "Анна", learnVoice: true)
        writer.releaseWriteLock()

        let unavailable = root.appendingPathComponent("not-a-catalogue")
        let savedCatalogue = root.appendingPathComponent("saved-catalogue")
        try FileManager.default.moveItem(at: profiles.directory, to: savedCatalogue)
        try FileManager.default.createSymbolicLink(at: profiles.directory, withDestinationURL: unavailable)
        let history = RecordingHistoryRepository(voiceLearning: coordinator)
        let runner = MockTranscriptionRunner()
        runner.delayNanoseconds = 0
        runner.onRun = { () async throws in
            let rival = TranscriptEditsRepository(recordingDirectory: directory)
            #expect(throws: TranscriptEditsError.self) { try rival.acquireWriteLock() }
            let stages = try profiles.load().catalogue.learningRecords?.map(\.stage)
            #expect(stages == [.committed])
        }
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(),
            historyRepository: history, voiceLearning: coordinator)
        let settings = ProcessingJobSettings(parakeet: false, echoCancellation: false)
        _ = await service.enqueue(recordingURL: recording, settings: settings)
        #expect(await service.totalJobCount == 0)
        #expect(runner.runCallCount == 0)
        try FileManager.default.removeItem(at: profiles.directory)
        try FileManager.default.moveItem(at: savedCatalogue, to: profiles.directory)
        let (events, continuation) = AsyncStream<ProcessingService.Event>.makeStream()
        await service.addEventHandler { event in
            continuation.yield(event)
            switch event { case .completed, .failed, .cancelled: continuation.finish(); default: break }
        }
        _ = await service.enqueue(recordingURL: recording, settings: settings)
        for await _ in events {}
        #expect(runner.runCallCount == 1)
        try writer.acquireWriteLock()
        writer.releaseWriteLock()
    }

    @Test func anotherJobStartsWhenVoiceAdmissionRejectsTheFirstRetry() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent(UUID().uuidString)
        let first = root.appendingPathComponent("first/first.m4a")
        let second = root.appendingPathComponent("second/second.m4a")
        for recording in [first, second] {
            try FileManager.default.createDirectory(at: recording.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let held = TranscriptEditsRepository(recordingDirectory: first.deletingLastPathComponent())
        try held.acquireWriteLock()
        defer { held.releaseWriteLock() }
        let voice = VoiceLearningCoordinator(catalogue: VoiceProfileCatalogueRepository(applicationDataDirectory: root))
        let (entered, enter) = AsyncStream<Void>.makeStream()
        let (release, releaseAdmission) = AsyncStream<Void>.makeStream()
        let (worker, releaseWorker) = AsyncStream<Void>.makeStream()
        let runner = MockTranscriptionRunner()
        runner.onRun = {
            var iterator = worker.makeAsyncIterator()
            _ = await iterator.next()
        }
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: MockAudioExporter(), retryAdmission: {
            if $0 == first {
                enter.yield(())
                var iterator = release.makeAsyncIterator()
                _ = await iterator.next()
            }
            return true
        }, voiceLearning: voice)
        let settings = ProcessingJobSettings(parakeet: false, echoCancellation: false)
        let firstTask = Task { await service.enqueue(recordingURL: first, settings: settings) }
        var enteredIterator = entered.makeAsyncIterator()
        _ = await enteredIterator.next()
        _ = await service.enqueue(recordingURL: second, settings: settings)
        #expect(await service.currentSnapshot().active == nil)
        releaseAdmission.yield(())
        _ = await firstTask.value
        let snapshot = await service.currentSnapshot()
        #expect(snapshot.active?.recordingURL == second)
        releaseWorker.finish()
        if let active = snapshot.active { await service.cancel(jobID: active.id) }
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
        let stopResult = try await session.stop(shortRecordingThreshold: 5.0, expectedSessionID: (await session.currentSnapshot).sessionID, cancelShort: true)
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
        let stopResult = try await session.stop(shortRecordingThreshold: 10.0, expectedSessionID: (await session.currentSnapshot).sessionID, cancelShort: true, trash: { url in
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
            .appendingPathComponent("Tests/Fixtures/transcript-document/valid_parakeet_off.json")
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
        _ = try await session.stop(expectedSessionID: (await session.currentSnapshot).sessionID)
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

    @Test func sessionIdentityRejectionOnStaleCommand() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder1 = root.appendingPathComponent("session1")
        try FileManager.default.createDirectory(at: folder1.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url1 = folder1.appendingPathComponent("session1.m4a")
        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)

        let mockController1 = MockAudioCaptureController(outputURL: url1)
        _ = try await session.start(controller: mockController1, outputURL: url1)
        let snap1 = await session.currentSnapshot
        let sessionID1 = try #require(snap1.sessionID)

        // Attempting to stop with a stale/mismatched session ID must be rejected
        let staleID = UUID()
        await #expect(throws: NSError.self) {
            _ = try await session.stop(expectedSessionID: staleID)
        }
        let stillRecording = await session.isRecording
        #expect(stillRecording, "Session must still be recording after stale stop rejection")

        // Mute with stale session ID must be ignored
        await session.setMicrophoneMuted(true, expectedSessionID: staleID)
        #expect(mockController1.isMuted == false, "Stale mute command must be ignored")

        // Mute with correct session ID succeeds
        await session.setMicrophoneMuted(true, expectedSessionID: sessionID1)
        #expect(mockController1.isMuted == true, "Matching mute command must succeed")

        // Stopping with matching session ID succeeds
        let stopRes = try await session.stop(expectedSessionID: sessionID1)
        #expect(stopRes.outputURL == url1)
        let isRecAfterStop = await session.isRecording
        #expect(!isRecAfterStop)
    }

    @Test func startingPhaseDistinctionAndSnapshotIntegrity() async throws {
        actor StartingGate {
            var continuation: CheckedContinuation<Void, Never>?
            let entered: AsyncStream<Void>.Continuation
            init(_ entered: AsyncStream<Void>.Continuation) { self.entered = entered }
            func wait() async { await withCheckedContinuation { continuation = $0; entered.yield(()) } }
            func open() { continuation?.resume(); continuation = nil }
        }

        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let folder = root.appendingPathComponent("starting_test")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("raw"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let url = folder.appendingPathComponent("starting_test.m4a")
        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)

        let mockController = MockAudioCaptureController(outputURL: url)
        let (entered, continuation) = AsyncStream<Void>.makeStream()
        let gate = StartingGate(continuation)
        mockController.suspendStart = { await gate.wait() }

        let startTask = Task {
            try await session.start(controller: mockController, outputURL: url)
        }

        var iterator = entered.makeAsyncIterator()
        _ = await iterator.next()

        // While starting, isRecording must be false, and phase must be .starting
        let startingSnap = await session.currentSnapshot
        if case .starting(let outputURL) = startingSnap.phase {
            #expect(outputURL == url)
        } else {
            #expect(Bool(false), "Phase must be .starting while capture is preparing")
        }
        let isRecStarting = await session.isRecording
        #expect(!isRecStarting, "isRecording must be false during starting phase")
        #expect(startingSnap.sessionID != nil, "Starting phase must have valid sessionID")

        await gate.open()
        _ = try await startTask.value
        let isRecStarted = await session.isRecording
        #expect(isRecStarted, "isRecording must be true once capture starts")
        _ = try await session.stop(expectedSessionID: (await session.currentSnapshot).sessionID)
    }
}

private struct OrderedProgressRunner: TranscriptionRunnerProtocol {
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        for count in 0...100 { onProgress?(.init(stage: .gigaam, channel: "host", completed: count, total: 100)) }
        for source in ["host", "remote"] {
            onProgress?(.init(stage: .speakers, channel: source, completed: 0, total: 0, state: .completed))
        }
        onProgress?(.init(stage: .publication, completed: 0, total: 0, warning: "Synthetic committed warning", state: .started))
        return recording.appendingPathExtension("txt")
    }
}

private actor QueuedProgressRunner: TranscriptionRunnerProtocol {
    private var continuations: [URL: CheckedContinuation<Void, Never>] = [:]
    func waiting(_ url: URL) -> Bool { continuations[url] != nil }
    func finish(_ url: URL) { continuations.removeValue(forKey: url)?.resume() }
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("synthetic", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        await withCheckedContinuation { continuations[recording] = $0 }
        return recording.appendingPathExtension("txt")
    }
}

private final class BoxedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

private struct InlineVoiceASRRunner: TranscriptionRunnerProtocol {
    let publish: @Sendable () throws -> URL
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("ok", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        onProgress?(.init(stage: .diarization, channel: "host", completed: 0, total: 0, state: .completed))
        onProgress?(.init(stage: .diarization, channel: "remote", completed: 0, total: 0, state: .completed))
        onProgress?(.init(stage: .gigaam, channel: "host", completed: 1, total: 1, state: .completed))
        onProgress?(.init(stage: .gigaam, channel: "remote", completed: 1, total: 1, state: .completed))
        onProgress?(.init(stage: .publication, completed: 1, total: 1, state: .completed))
        return try publish()
    }
}

private struct InlineVoiceEmbeddingRunner: VoiceEmbeddingRunnerProtocol {
    let runExtract: @Sendable (VoiceEmbeddingProtocol.Request) async throws -> VoiceEmbeddingProtocol.Response
    func checkOrPrepareVoiceModel(prepare: Bool) async throws {}
    func extractVoiceEmbeddings(_ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL) async throws -> VoiceEmbeddingProtocol.Response {
        try await runExtract(request)
    }
}

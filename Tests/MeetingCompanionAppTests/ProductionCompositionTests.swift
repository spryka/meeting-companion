import Foundation
import Testing
import MeetingCompanionCore
import MeetingCompanionApplication
@testable import MeetingCompanionApp

private struct Exporter: AudioExporterProtocol {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws {}
}
private struct Runner: TranscriptionRunnerProtocol {
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) {
        try await Task.sleep(for: .seconds(30)); return ("checked", true)
    }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        try await Task.sleep(for: .seconds(30)); return recording
    }
}
private struct Capture: AudioCaptureControllerProtocol {
    let output: URL
    func startCapture() async throws {}
    func stopCapture() async throws -> AudioCaptureStopResult { .init(duration: 15, outputURL: output) }
    func setMicrophoneMuted(_ muted: Bool) {}
    func currentMicrophoneState() -> MicrophoneRecordingState { .receiving }
}
@Suite @MainActor struct ProductionCompositionTests {

    @Test func flatNeighboursCannotUseSharedStructuredResultOrMutateMetadata() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        for stem in ["meeting_A", "meeting_B"] {
            let url = root.appendingPathComponent(stem + ".m4a")
            let metadata = root.appendingPathComponent(stem + ".processing.json")
            var saved = RecordingEntry(recording: url, date: Date(), title: "Saved " + stem, phase: .completed)
            saved.duration = 456
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(saved)
            let precise = Data("{\"precise\":123456789012345678901234567890.123456789}".utf8)
            let bytes = try TranscriptResultStorage.mergeUnknownFields(from: precise, into: data)
            try bytes.write(to: metadata)
            try Data(("Saved " + stem).utf8).write(to: url.deletingPathExtension().appendingPathExtension("sources.transcript.txt"))
            let entry = RecordingEntry.load(recording: url)
            #expect(entry.title == "Saved " + stem && entry.duration == 456)
            #expect(entry.metadata == metadata)
            #expect(!entry.capabilities.canReview && !entry.capabilities.canRetry && !entry.capabilities.canPreviewAudio)
            #expect(throws: Error.self) { try TranscriptResultStorage(recordingURL: url).currentDocument() }
            #expect(try TranscriptReviewSession.open(recordingURL: url) == nil)
            let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
            #expect(state.isReadOnly && state.session == nil)
            let model = try await TranscriptReviewWindowModel(state: state)
            #expect(model.legacyText == "Saved " + stem)
            #expect(!model.canExport && !model.playbackEnabled)
            let repo = RecordingHistoryRepository()
            repo.put(entry, persist: false)
            #expect(throws: Error.self) { try repo.putThrowing(saved) }
            #expect(throws: Error.self) { try repo.updateThrowing(url) { $0.title = "Changed" } }
            #expect(repo.updateStatus(url) { $0.title = "Changed" }.persistenceWarning != nil)
            #expect(repo.update(url) { $0.title = "Changed" }.persistenceWarning != nil)
            #expect(repo.put(saved).persistenceWarning != nil)
            #expect(repo.entry(url)?.title == "Saved " + stem)
            #expect(try Data(contentsOf: metadata) == bytes)
            #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("raw/" + stem + ".processing.json").path))
            model.close(); state.close()
        }
    }

    @Test func flatMetadataReadPathDoesNotChangeWhenRawAppears() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting_B.m4a")
        let entry = RecordingEntry(recording: url, date: Date(), title: "Saved B", phase: .completed)
        let metadata = root.appendingPathComponent("meeting_B.processing.json")
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let bytes = try TranscriptResultStorage.mergeUnknownFields(
            from: Data("{\"precise\":123456789012345678901234567890.123456789}".utf8), into: encoder.encode(entry))
        try bytes.write(to: metadata)
        #expect(RecordingEntry.load(recording: url).title == "Saved B")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw/transcripts"), withIntermediateDirectories: true)
        #expect(RecordingEntry.load(recording: url).title == "Saved B")
        #expect(RecordingEntry.load(recording: url).metadata == metadata)
        #expect(throws: Error.self) { try RecordingHistoryRepository().putThrowing(entry) }
        #expect(try Data(contentsOf: metadata) == bytes)
    }

    @Test func flatWithoutTXTDoesNotOpenNeighbourResult() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("other.m4a")
        let entry = RecordingEntry.load(recording: url)
        #expect(!entry.capabilities.canReview && !entry.capabilities.canRetry && !entry.capabilities.hasSavedText)
        await #expect(throws: TranscriptWindowError.self) { try await TranscriptWindowCoordinator().openWindow(for: url) }
    }

    @Test func standardOwnerWithoutOriginalsKeepsEditorAndPlaybackAndIsolatesNeighbour() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        try Data([1]).write(to: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/mix.m4a"))
        try Data([2]).write(to: root.appendingPathComponent("meeting.m4a"))
        let owner = root.appendingPathComponent("meeting.m4a")
        let neighbour = root.appendingPathComponent("other.m4a")
        let entry = RecordingEntry.load(recording: owner)
        #expect(entry.capabilities.canReview && entry.capabilities.canPreviewAudio)
        #expect(!entry.capabilities.canRetry)
        let repo = RecordingHistoryRepository()
        try repo.putThrowing(entry)
        #expect(throws: Error.self) { try repo.updateThrowing(neighbour) { $0.title = "Foreign" } }
        let coordinator = TranscriptWindowCoordinator()
        let state = try await coordinator.openWindow(for: owner).state
        #expect(!state.isReadOnly && state.session != nil)
        let session = try #require(state.session)
        #expect(session.activeResultID == "res_valid_parakeet_off")
        await #expect(throws: TranscriptWindowError.self) { try await coordinator.openWindow(for: neighbour) }
        #expect(try TranscriptResultStorage(recordingURL: owner).currentDocument()?.resultID == "res_valid_parakeet_off")
        #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("other.processing.json").path))
        state.close()
    }

    @Test(arguments: ["recording", "preparing", "checking"]) func constructorReattachesToAuthoritativeServices(activity: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let repo = RecordingHistoryRepository()
        let session = RecordingSessionService(historyRepo: repo)
        let processing = ProcessingService(transcriptionRunner: Runner(), audioExporter: Exporter(), historyRepository: repo)
        let output = root.appendingPathComponent("meeting.m4a")
        let task: Task<Void, Never>?
        if activity != "recording" {
            task = Task { _ = try? await processing.checkOrPrepareDependencies(prepare: activity == "preparing", parakeet: false) }
            while await processing.currentPreparationState == .idle { await Task.yield() }
        } else {
            task = nil
            _ = try await session.start(controller: Capture(output: output), outputURL: output, meetingID: "meeting", meetingSummary: "Meeting")
        }
        let model = RecorderViewModel(sessionService: session, processingService: processing,
            historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        for _ in 0..<100 { await Task.yield() }
        #expect(model.preventsTermination)
        #expect(!model.canResetCache)
        if activity != "recording" { #expect(model.diagnosticRunning) }
        else { #expect(model.isRecording); #expect(model.lastFileURL == output); #expect(model.recordingMeetingID == "meeting") }
        if activity != "recording" { await processing.cancelPreparation(); await task?.value }
        else { _ = try await session.stop() }
        for _ in 0..<1000 { if !model.preventsTermination { break }; await Task.yield() }
        #expect(!model.preventsTermination)
        #expect(model.canResetCache)
    }
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("raw"), withIntermediateDirectories: true)
        return root
    }

    private func published(_ id: String, in root: URL) throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("transcription/fixtures/transcript-document/valid_parakeet_off.json")
        var json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fixture)) as? [String: Any])
        json["resultID"] = id
        if var playback = json["playback"] as? [String: Any] {
            playback["mixPath"] = "raw/transcripts/" + id + "/mix.m4a"
            json["playback"] = playback
        }
        let directory = root.appendingPathComponent("raw/transcripts/" + id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: json).write(to: directory.appendingPathComponent("result.json"))
        _ = try TranscriptDocument.load(from: directory.appendingPathComponent("result.json"), recordingDirectory: root)
    }

    private func sources(in root: URL, stem: String = "meeting", flat: Bool = false) throws {
        for source in ["host", "remote"] {
            // Existence/readability is retry eligibility; the existing worker validates audio decoding.
            try Data([0, 0]).write(to: (flat ? root : root.appendingPathComponent("raw"))
                .appendingPathComponent(stem + "." + source + "_record.wav"))
        }
    }

    @Test(arguments: [false, true]) func supportedUnmarkedJSONKeepsCapabilitiesWithoutTXT(flat: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try sources(in: root, flat: flat)
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let bytes = try Data(contentsOf: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/result.json"))
        let entry = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(entry.capabilities.canReview)
        #expect(entry.capabilities.canRetry == !flat)
        #expect(!entry.capabilities.hasSavedText)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(!state.isReadOnly)
        #expect(state.activeResultID == "res_valid_parakeet_off")
        #expect(try Data(contentsOf: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/result.json")) == bytes)
        #expect(!FileManager.default.fileExists(atPath: entry.metadata.path))
    }

    @Test(arguments: [false, true], [false, true]) func corruptOrMissingCurrentResultRemainsRetryable(missing: Bool, flat: Bool) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.m4a")
        try sources(in: root, flat: flat)
        if !missing {
            let result = root.appendingPathComponent("raw/transcripts/broken")
            try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
            try Data("{broken".utf8).write(to: result.appendingPathComponent("result.json"))
        }
        let entry = RecordingEntry(recording: url, date: Date(), title: "Current", phase: .failed)
        try RecordingHistoryRepository().putThrowing(entry)
        try Data("saved recognized text".utf8).write(to: entry.transcript)
        let loaded = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(loaded.capabilities.canRetry == !flat)
        #expect(!loaded.capabilities.canReview)
        #expect(loaded.isLegacy == flat)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(state.isReadOnly)
        if !missing, case .legacyReadOnly = state.mode { Issue.record("Corrupt current result was masked as a clean standalone TXT") }
        let model = try await TranscriptReviewWindowModel(state: state)
        #expect(model.legacyText == "saved recognized text")
        #expect(!model.canExport)
        #expect(!model.playbackEnabled)
        #expect(model.explanation != nil)
    }

    @Test(arguments: ["{}", "{\"selectedResultID\":\"res_valid_parakeet_off\"}",
        "{\"recordingFormatVersion\":999}", "{\"recordingFormatVersion\":\"future\"}",
        "{\"recordingFormatVersion\":1,\"recordingFormatVersion\":999}",
        "{\"recordingFormatVersion\":999,\"recordingFormatVersion\":1}"])
    func minimalMetadataRespectsArtifactAndFormatContracts(metadata: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("meeting.m4a")
        try sources(in: root)
        try published("res_valid_parakeet_off", in: root)
        let metadataURL = root.appendingPathComponent("raw/meeting.processing.json")
        let bytes = Data(metadata.utf8)
        try bytes.write(to: metadataURL)
        try Data("saved text".utf8).write(to: root.appendingPathComponent("meeting.sources.transcript.txt"))
        let entry = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(entry.capabilities.canReview)
        #expect(entry.capabilities.canRetry)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(!state.isReadOnly)
        #expect(try Data(contentsOf: metadataURL) == bytes)
    }



    @Test func historyMutationRunsOffMainActorAndIsAwaited() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let entry = RecordingEntry(recording: root.appendingPathComponent("meeting.m4a"), date: Date(), title: "Before", phase: .completed)
        let history = RecordingHistory()
        await history.put(entry)
        let (started, continuation) = AsyncStream<Bool>.makeStream()
        let gate = DispatchSemaphore(value: 0)
        let mutation = Task {
            await history.update(entry.id) {
                continuation.yield(Thread.isMainThread)
                _ = gate.wait(timeout: .now() + 2)
                $0.title = "After"
            }
        }
        for await mainThread in started {
            #expect(!mainThread)
            #expect(history.entry(entry.id)?.title == "Before")
            gate.signal()
            break
        }
        await mutation.value
        #expect(history.entry(entry.id)?.title == "After")
        #expect(RecordingEntry.load(recording: entry.id).title == "After")
    }

    @Test func constructorReattachesQueueAndContinuesEventsWithoutDoubleCount() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(root.path, forKey: "recordingsDirectory")
        let repo = RecordingHistoryRepository()
        let processing = ProcessingService(transcriptionRunner: Runner(), audioExporter: Exporter(), historyRepository: repo)
        var jobs: [ProcessingJob] = []
        for name in ["first", "second"] {
            let owned = root.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: owned.appendingPathComponent("raw"), withIntermediateDirectories: true)
            try sources(in: owned, stem: name)
            let url = owned.appendingPathComponent(name + ".m4a")
            try repo.putThrowing(RecordingEntry(recording: url, date: Date(), title: name, phase: .failed))
            jobs.append(await processing.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false)))
        }
        let model = RecorderViewModel(sessionService: RecordingSessionService(historyRepo: repo), processingService: processing,
            historyRepository: repo, defaults: defaults, startBackgroundServices: false)
        #expect(model.preventsTermination)
        for _ in 0..<1000 { if model.transcriptionJobs == 2 { break }; await Task.yield() }
        #expect(model.transcriptionJobs == 2)
        #expect(model.lastFileURL == jobs[0].recordingURL)
        #expect(!model.canResetCache)
        await processing.cancel(jobID: jobs[1].id)
        for _ in 0..<1000 { if model.transcriptionJobs == 1 { break }; await Task.yield() }
        #expect(model.transcriptionJobs == 1)
        await processing.cancel(jobID: jobs[0].id)
        for _ in 0..<1000 { if model.transcriptionJobs == 0 { break }; await Task.yield() }
        #expect(model.transcriptionJobs == 0)
        #expect(model.canResetCache)
        #expect(!model.preventsTermination)
    }

    @Test func lifecycleReloadIgnoresAndPreservesObsoleteMetadata() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try sources(in: root)
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let metadata = root.appendingPathComponent("raw/meeting.processing.json")
        let precise = "123456789012345678901234567890.1234567890123456789"
        let bytes = Data(("{\"selectedResultID\":\"gone\",\"recordingFormatVersion\":1,\"recordingFormatVersion\":999,\"precise\":" + precise + "}").utf8)
        try bytes.write(to: metadata)
        let repo = RecordingHistoryRepository()
        let service = RecordingSessionService(historyRepo: repo)
        _ = try await service.start(controller: Capture(output: url), outputURL: url)
        _ = try await service.stop()
        for _ in 0..<3 { _ = repo.updateStatus(url) { $0.phase = .completed } }
        let disk = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(disk.capabilities.canReview && disk.capabilities.canRetry)
        let text = try String(contentsOf: metadata, encoding: .utf8)
        #expect(text.contains(precise))
        #expect(text.components(separatedBy: "\"recordingFormatVersion\"").count - 1 == 2)
        #expect(text.contains("gone"))
        let window = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(!window.isReadOnly)
        #expect(window.activeResultID == "res_valid_parakeet_off")
    }

    @Test(arguments: ["unsupported", "corrupt", "missing"])
    func newestDirectoryCannotFallBackToOldSelectedResult(kind: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        try sources(in: root)
        let a = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: a.path)
        let b = root.appendingPathComponent("raw/transcripts/newest")
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        if kind == "unsupported" { try Data("{\"schemaVersion\":2}".utf8).write(to: b.appendingPathComponent("result.json")) }
        if kind == "corrupt" { try Data("{broken".utf8).write(to: b.appendingPathComponent("result.json")) }
        let metadata = root.appendingPathComponent("raw/meeting.processing.json")
        let oldSelection = Data("{\"selectedResultID\":\"res_valid_parakeet_off\"}".utf8)
        try oldSelection.write(to: metadata)
        try Data("explicitly saved old text".utf8).write(to: root.appendingPathComponent("meeting.sources.transcript.txt"))
        let url = root.appendingPathComponent("meeting.m4a")
        let entry = await Task.detached { RecordingEntry.load(recording: url) }.value
        #expect(!entry.capabilities.canReview)
        #expect(entry.capabilities.canRetry)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(state.isReadOnly && state.session == nil)
        #expect(try Data(contentsOf: metadata) == oldSelection)
    }

    @Test(arguments: ["save", "discard", "cancel"])
    func guiRetryResolvesDraftBeforeAdmission(choice: String) async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try sources(in: root)
        try published("res_valid_parakeet_off", in: root)
        let url = root.appendingPathComponent("meeting.m4a")
        let repo = RecordingHistoryRepository()
        repo.put(RecordingEntry.load(recording: url), persist: false)
        let coordinator = TranscriptWindowCoordinator()
        let state = try await coordinator.openWindow(for: url).state
        let editor = try await TranscriptReviewWindowModel(state: state)
        let turn = try #require(editor.rows.first?.id)
        editor.openTextEditing(for: turn)
        editor.updateDraftText("Manual correction")
        let service = ProcessingService(transcriptionRunner: Runner(), audioExporter: Exporter(), historyRepository: repo,
            retryAdmission: { _ in await editor.resolveForRetry() })
        let task = Task { await service.enqueue(recordingURL: url, settings: .init(parakeet: false, echoCancellation: false)) }
        for _ in 0..<1000 { if editor.unsavedPrompt != nil { break }; await Task.yield() }
        let prompt = try #require(editor.unsavedPrompt)
        #expect(await service.isProcessing(recordingURL: url))
        #expect(!state.isClosed)
        editor.resolveUnsavedPrompt(choice == "save" ? .save : choice == "discard" ? .discard : .stay, promptID: prompt.id)
        let job = await task.value
        let editsURL = root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off/edits.json")
        if choice == "cancel" {
            #expect(!state.isClosed)
            #expect(editor.hasUnsavedChanges)
            #expect(await service.totalJobCount == 0)
            #expect(!FileManager.default.fileExists(atPath: editsURL.path))
        } else {
            #expect(state.isClosed && state.session == nil)
            #expect(await service.isProcessing(recordingURL: url))
            let manager = TranscriptReviewWindowManager(isProcessing: { await service.isProcessing(recordingURL: $0) })
            await #expect(throws: TranscriptWindowError.self) { try await manager.open(recordingURL: url, title: "Blocked") }
            if choice == "save" {
                let edits = try TranscriptEditsRepository(recordingDirectory: root).loadEdits(resultID: "res_valid_parakeet_off")
                #expect(edits.overrides[turn]?.text == "Manual correction")
            } else { #expect(!FileManager.default.fileExists(atPath: editsURL.path)) }
            await service.cancel(jobID: job.id)
            #expect(!(await service.isProcessing(recordingURL: url)))
            // Terminal reopen re-resolves disk, with no old draft or old edits mapped to B.
            try published("replacement", in: root)
            try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: root.appendingPathComponent("raw/transcripts/res_valid_parakeet_off").path)
            let next = try await coordinator.openWindow(for: url).state
            let reopened = try await TranscriptReviewWindowModel(state: next)
            #expect(reopened.currentResultID == "replacement")
            #expect(!reopened.hasUnsavedChanges)
            #expect(!reopened.rows.contains { $0.text == "Manual correction" })
        }
        editor.close()
        coordinator.closeAll()
    }

    @Test func retryPromptRejectsChangedDraftWithoutLosingIt() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try published("res_valid_parakeet_off", in: root)
        let state = try await TranscriptWindowCoordinator().openWindow(for: root.appendingPathComponent("meeting.m4a")).state
        let editor = try await TranscriptReviewWindowModel(state: state)
        editor.openTextEditing(for: try #require(editor.rows.first?.id))
        editor.updateDraftText("First")
        let task = Task { await editor.resolveForRetry() }
        for _ in 0..<1000 { if editor.unsavedPrompt != nil { break }; await Task.yield() }
        let prompt = try #require(editor.unsavedPrompt)
        editor.updateDraftText("New draft")
        editor.resolveUnsavedPrompt(.discard, promptID: prompt.id)
        #expect(await task.value == false)
        #expect(editor.activeTextDraft?.text == "New draft")
        #expect(!state.isClosed)
        editor.close(); state.close()
    }

    @Test func committedStructuredCurrentDoesNotReadRootExportCache() async throws {
        let root = try fixtureRoot()
        let outside = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        try published("res_valid_parakeet_off", in: root)
        let saved = outside.appendingPathComponent("saved.txt")
        try Data("Stale unrelated export".utf8).write(to: saved)
        let url = root.appendingPathComponent("meeting.m4a")
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("meeting.sources.transcript.txt"), withDestinationURL: saved)
        let state = try await TranscriptWindowCoordinator().openWindow(for: url).state
        #expect(!state.isReadOnly)
        #expect(state.activeResultID == "res_valid_parakeet_off")
        let editor = try await TranscriptReviewWindowModel(state: state)
        #expect(editor.legacyText == nil)
        #expect(!editor.rows.isEmpty)
        editor.close(); state.close()
    }

}

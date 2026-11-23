import Darwin
import Foundation
import MeetingCompanionApplication
import MeetingCompanionCore
import Synchronization
import Testing

private struct LearningWorker: TranscriptionRunnerProtocol, VoiceEmbeddingRunnerProtocol, AudioExporterProtocol {
    let beforeReply: @Sendable () throws -> Void

    func checkDependenciesWithOutput(
        prepare: Bool, availability: Bool, parakeet: Bool, onOutput: (@Sendable (String) -> Void)?
    ) async throws -> (output: String, succeeded: Bool) { throw TranscriptEditsError.notImplemented }

    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
             onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        throw TranscriptEditsError.notImplemented
    }

    func exportMixedAudio(from inputs: [URL], to output: URL) async throws { throw TranscriptEditsError.notImplemented }

    func extractVoiceEmbeddings(
        _ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL
    ) async throws -> VoiceEmbeddingProtocol.Response {
        try beforeReply()
        return .init(requestID: request.id, features: request.windows.map {
            .init(windowID: $0.id, pcmFingerprint: String(repeating: "b", count: 64),
                  embedding: [Float(1)] + Array(repeating: 0, count: 255))
        })
    }
}

@Suite struct VoiceLearningCoordinatorTests {
    private static let resultID = "res_valid_empty_voices"
    private static let turnID = "turn_1"

    @Test func reconciliationSharesWriterWithoutAdvancingItsCAS() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording)
        _ = try writer.saveTurnOverride(resultID: Self.resultID, turnID: Self.turnID, text: "Own edit", displayName: nil)
        let original = try #require(writer.loadedSnapshot(for: Self.resultID))
        let edits = writer.editsURL(for: Self.resultID)
        var changed = try Data(contentsOf: edits)
        changed.append(0x20)
        try changed.write(to: edits, options: .atomic)

        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let url = f.recording.appendingPathComponent("meeting_synthetic.m4a")
        coordinator.reconcileLibrary(recordings: [url], scanComplete: true, id: coordinator.beginLibraryReconciliation(), openWriters: [writer])
        #expect(coordinator.canMatchVoices)
        #expect(writer.loadedSnapshot(for: Self.resultID)?.data == original.data)
        #expect(writer.canUndo(resultID: Self.resultID))
        #expect(throws: TranscriptEditsError.self) {
            try writer.saveTurnOverride(resultID: Self.resultID, turnID: Self.turnID, text: "Stale edit", displayName: nil)
        }
    }

    @Test func backgroundSnapshotReleasesOnlyItsOwnLock() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let reader = TranscriptEditsRepository(recordingDirectory: f.recording)
        let editor = TranscriptEditsRepository(recordingDirectory: f.recording)
        try reader.withLockedEditsSnapshot(resultID: Self.resultID) { _ in
            #expect(throws: TranscriptEditsError.self) { try editor.acquireWriteLock() }
        }
        try editor.acquireWriteLock()
        try editor.withLockedEditsSnapshot(resultID: Self.resultID) { _ in }
        #expect(throws: TranscriptEditsError.self) { try reader.acquireWriteLock() }
    }

    @Test func repairingResultReconciliationClearsItsLockFailure() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording)
        try writer.acquireWriteLock()
        defer { writer.releaseWriteLock() }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let recording = f.recording.appendingPathComponent("meeting_synthetic.m4a")
        coordinator.reconcileLibrary(recordings: [recording], scanComplete: true, id: coordinator.beginLibraryReconciliation())
        #expect(coordinator.failure(for: f.recording) != nil)
        #expect(!coordinator.canMatchVoices)

        try coordinator.reconcile(writer: writer, resultID: Self.resultID)
        #expect(coordinator.failure(for: f.recording) == nil)
        #expect(coordinator.canMatchVoices)
    }

    @Test func destructiveAdmissionSkipsUnreadableResultOnlyWithoutEdits() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording)
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let recording = f.recording.appendingPathComponent("meeting_synthetic.m4a")
        let edits = writer.editsURL(for: Self.resultID)
        try FileManager.default.removeItem(at: edits)
        try Data("broken recognition".utf8).write(to: writer.resultURL(for: Self.resultID))
        try coordinator.preserveOutboxes(recording: recording, writer: writer, includeHistory: true)
        try Data("possible edits".utf8).write(to: edits)
        #expect(throws: TranscriptEditsError.self) {
            try coordinator.preserveOutboxes(recording: recording, writer: writer, includeHistory: true)
        }
    }

    private struct Fixture {
        let root: URL
        let recording: URL
        let catalogue: VoiceProfileCatalogueRepository
        let oldPerson = VoiceProfilePerson(displayName: "Анна")
        let newPerson = VoiceProfilePerson(displayName: "Анна")
        private var catalogueID: UUID?

        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("voice-learning-\(UUID().uuidString)", isDirectory: true)
            recording = root.appendingPathComponent("meeting_synthetic", isDirectory: true)
            catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
            let writer = TranscriptEditsRepository(recordingDirectory: recording)
            let result = writer.resultURL(for: VoiceLearningCoordinatorTests.resultID)
            try FileManager.default.createDirectory(at: result.deletingLastPathComponent(), withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Fixtures/transcript-document/valid_empty_voices.json")
            try FileManager.default.copyItem(at: source, to: result)
            let assignment = TranscriptNameAssignment(personID: oldPerson.id, origin: "manual")
            let saved = try writer.saveEdits(resultID: VoiceLearningCoordinatorTests.resultID, overrides: [
                VoiceLearningCoordinatorTests.turnID: TranscriptTurnOverride(displayName: oldPerson.displayName, assignment: assignment)
            ])
            let vector = [Float(1)] + Array(repeating: 0, count: 255)
            let sample = VoiceProfileSample(personID: oldPerson.id, embeddingSpaceID: "test", embedding: vector,
                recordingLocator: recording.path, resultID: saved.resultID, turnID: VoiceLearningCoordinatorTests.turnID,
                sourceID: .host, start: 0.5, end: 1, pcmFingerprint: "pcm",
                assignment: assignment, policyID: "test")
            let stored = try catalogue.update(catalogue.load()) {
                $0.people = [oldPerson, newPerson]
                $0.samples = [sample]
                $0.aggregates = [.init(personID: oldPerson.id, embeddingSpaceID: "test", centroid: vector,
                                      activeSampleIDs: [sample.id], policyID: "test")]
            }
            catalogueID = stored.catalogue.instanceID
        }

        func confirmed(_ person: VoiceProfilePerson) throws -> TranscriptPersonSelection {
            .confirmed(.init(personID: person.id, nameToCreate: nil, catalogueID: try #require(catalogueID),
                             catalogueGeneration: 0, personGeneration: person.generation))
        }

        func correct(using writer: TranscriptEditsRepository, learn: Bool = true,
                     selection: TranscriptPersonSelection? = nil) throws -> TranscriptEdits {
            let service = TranscriptSpeakerAssignmentService(editsRepository: writer)
            let preview = try service.previewAssignment(
                resultID: VoiceLearningCoordinatorTests.resultID, anchorTurnID: VoiceLearningCoordinatorTests.turnID,
                scope: .single, displayName: newPerson.displayName, person: try selection ?? confirmed(newPerson)
            )
            return try service.assignSpeakerName(preview: preview, displayName: newPerson.displayName, learnVoice: learn)
        }
    }

    private enum Interrupted: Error { case beforeRename }

    enum LearningInterruption: CaseIterable, Sendable { case none, disableAndEnable, resetPerson }

    @Test(arguments: [false, true], [false, true])
    func restartResumesOnlyTheStillEnabledLearningGeneration(reenabled: Bool, damagedNeighbor: Bool) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let original = VoiceLearningCoordinator(catalogue: f.catalogue)
        let generation = UUID()
        original.setEnabled(true, generation: generation)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: original.observe)
        let result = writer.resultURL(for: Self.resultID)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
        for key in ["words", "baselineWords", "turns"] {
            var items = try #require(json[key] as? [[String: Any]])
            items[0]["end"] = 5.0
            json[key] = items
        }
        try JSONSerialization.data(withJSONObject: json).write(to: result)
        let document = try TranscriptDocument.load(from: result, recordingDirectory: f.recording)
        let source = try #require(document.sources.first { $0.id == .host })
        let quality = VoiceAudioQuality(resultID: Self.resultID, producer: "test", sources: [
            .init(id: .host, recognitionAudioPath: source.recognitionAudioPath,
                  fingerprint: String(repeating: "a", count: 64), duration: 5, speech: nil, overlap: [])
        ], recordingFingerprint: String(repeating: "c", count: 64))
        try quality.encoded(for: document).write(to: result.deletingLastPathComponent().appendingPathComponent(VoiceAudioQuality.filename))
        let selection = try original.personSelection(.existing(f.newPerson.id), displayName: f.newPerson.displayName)
        _ = try f.correct(using: writer, selection: selection)
        #expect(try f.catalogue.load().catalogue.learningRecords?.last?.stage == .committed)
        writer.releaseWriteLock()

        let restarted = VoiceLearningCoordinator(catalogue: f.catalogue)
        restarted.setEnabled(true, generation: reenabled ? UUID() : generation)
        let recording = f.recording.appendingPathComponent("meeting_synthetic.m4a")
        var recordings = [recording]
        if damagedNeighbor {
            let neighbor = f.root.appendingPathComponent("meeting_damaged")
            let bad = TranscriptEditsRepository(recordingDirectory: neighbor).resultURL(for: "broken")
            try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("invalid document".utf8).write(to: bad)
            recordings.append(neighbor.appendingPathComponent("meeting_damaged.m4a"))
        }
        restarted.reconcileLibrary(recordings: recordings, scanComplete: true, id: restarted.beginLibraryReconciliation())
        #expect(restarted.canMatchVoices == !damagedNeighbor)
        let calls = Mutex(0)
        let worker = LearningWorker { calls.withLock { $0 += 1 } }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        await restarted.resumeCommitted(recordings: recordings, processing: processing, policy: policy)
        await restarted.resumeCommitted(recordings: recordings, processing: processing, policy: policy)
        #expect(calls.withLock { $0 } == (reenabled ? 0 : 1))
        #expect(try f.catalogue.load().catalogue.samples.isEmpty == reenabled)
        #expect(try f.catalogue.load().catalogue.learningRecords?.last?.stage == (reenabled ? .committed : .applied))
    }

    enum AutomaticInterruption: CaseIterable, Sendable {
        case none, noCompatibleProfiles, manualEdit, newResult, changeLibrary, changedLibraryBeforeExtraction, disableAndEnable, resetPerson
    }

    @Test(arguments: [false, true]) func correctingNameRevokesSamplesFromEarlierImport(unboundV2: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let saved = TranscriptTurnOverride(displayName: f.oldPerson.displayName,
            assignment: unboundV2 ? .init(personID: nil, origin: "manual") : nil)
        let previous = try #require(saved.assignment ?? saved.legacyImportAssignment(
            resultID: Self.resultID, turnID: Self.turnID, personID: nil))
        let imported = TranscriptNameAssignment(assignmentID: previous.assignmentID, personID: f.oldPerson.id,
            origin: "legacyManualImport")
        let legacy = TranscriptEdits(schemaVersion: unboundV2 ? 2 : 1, resultID: Self.resultID, revision: 1,
                                   overrides: [Self.turnID: saved])
        try JSONEncoder().encode(legacy).write(to: writer.editsURL(for: Self.resultID))
        try Data([1]).write(to: writer.lockURL())
        let vector = [Float(1)] + Array(repeating: 0, count: 255)
        _ = try f.catalogue.update(f.catalogue.load()) { value in
            value.aggregates = []
            value.samples = [.init(personID: f.oldPerson.id, embeddingSpaceID: "test", embedding: vector,
                recordingLocator: f.recording.path, resultID: Self.resultID, turnID: Self.turnID, sourceID: .host,
                start: 0, end: 4, pcmFingerprint: "old-import", assignment: imported, policyID: "test")]
        }
        _ = try writer.saveTurnOverride(resultID: Self.resultID, turnID: Self.turnID, text: nil, displayName: "Исправление")
        #expect(try f.catalogue.load().catalogue.samples.isEmpty)
    }

    @Test(arguments: [false, true])
    func bulkLearningRequestsAtMostFourWindowsForOnePerson(workerFails: Bool) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        coordinator.setEnabled(true)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let result = writer.resultURL(for: Self.resultID)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
        for key in ["words", "baselineWords", "turns"] {
            let first = try #require((json[key] as? [[String: Any]])?.first)
            json[key] = (1...3).map { index in
                var item = first
                item["start"] = 20.0 * Double(index - 1)
                item["end"] = 20.0 * Double(index - 1) + 15
                item["id"] = key == "turns" ? "turn_\(index)" : "w_\(index)"
                if key == "turns" { item["wordIDs"] = ["w_\(index)"] }
                return item
            }
        }
        try JSONSerialization.data(withJSONObject: json).write(to: result)
        let document = try TranscriptDocument.load(from: result, recordingDirectory: f.recording)
        let source = try #require(document.sources.first { $0.id == .host })
        let quality = VoiceAudioQuality(resultID: Self.resultID, producer: "test", sources: [
            .init(id: .host, recognitionAudioPath: source.recognitionAudioPath,
                  fingerprint: String(repeating: "a", count: 64), duration: 55, speech: nil, overlap: [])
        ], recordingFingerprint: String(repeating: "c", count: 64))
        try quality.encoded(for: document).write(to: result.deletingLastPathComponent().appendingPathComponent(VoiceAudioQuality.filename))
        let service = TranscriptSpeakerAssignmentService(editsRepository: writer)
        let preview = try service.previewAssignment(resultID: Self.resultID, anchorTurnID: Self.turnID,
            scope: .group, displayName: f.newPerson.displayName, person: try f.confirmed(f.newPerson), replaceManuallyAssigned: true)
        let edits = try service.assignSpeakerName(preview: preview, displayName: f.newPerson.displayName, learnVoice: true)
        let calls = Mutex(0)
        let worker = LearningWorker {
            calls.withLock { $0 += 1 }
            if workerFails { throw Interrupted.beforeRename }
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        await coordinator.learnCommitted(events: try #require(edits.pendingLearningEvents), writer: writer, processing: processing,
            policy: try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8)),
            expectedGeneration: try #require(coordinator.featureGeneration))
        #expect(calls.withLock { $0 } == (workerFails ? 1 : 2))
        let catalogue = try f.catalogue.load().catalogue
        #expect(catalogue.learningRecords?.count == 3)
        #expect(catalogue.learningRecords?.filter { $0.stage == .applied }.count == (workerFails ? 0 : 1))
        #expect(catalogue.learningRecords?.contains { $0.outcome == "Лимит фрагментов этой правки достигнут." } == true)
        if workerFails {
            let displayed = catalogue.latestLearningUpdate(for: f.newPerson.id)
            #expect(displayed?.stage == .committed && displayed?.outcome != nil)
        }
    }

    @Test(arguments: AutomaticInterruption.allCases)
    func automaticAssignmentCommitsOnlyAnUnchangedNewResult(_ interruption: AutomaticInterruption) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        coordinator.setEnabled(true)
        coordinator.reconcileLibrary(recordings: [], scanComplete: true, id: coordinator.beginLibraryReconciliation())
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording)
        let result = writer.resultURL(for: Self.resultID)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
        let nextTurn = "turn_2"
        for key in ["words", "baselineWords", "turns"] {
            var items = try #require(json[key] as? [[String: Any]])
            var second = items[0]
            second["start"] = 2.0
            second["end"] = 7.0
            second["id"] = key == "turns" ? nextTurn : "w_2"
            if key == "turns" { second["wordIDs"] = ["w_2"] }
            items.append(second)
            json[key] = items
        }
        let raw = try JSONSerialization.data(withJSONObject: json)
        try raw.write(to: result)
        let document = try TranscriptDocument.load(from: result, recordingDirectory: f.recording)
        let source = try #require(document.sources.first { $0.id == .host })
        let quality = VoiceAudioQuality(resultID: Self.resultID, producer: "test", sources: [
            .init(id: .host, recognitionAudioPath: source.recognitionAudioPath,
                  fingerprint: String(repeating: "a", count: 64), duration: 7,
                  speech: [.init(start: 0, end: 7)], overlap: [])
        ], recordingFingerprint: String(repeating: "c", count: 64))
        try quality.encoded(for: document).write(to: result.deletingLastPathComponent().appendingPathComponent(VoiceAudioQuality.filename))
        _ = try f.catalogue.update(f.catalogue.load()) { catalogue in
            let people = [f.oldPerson, f.newPerson]
            let vectors = [[Float(1)] + Array(repeating: 0, count: 255),
                           [Float(0), 1] + Array(repeating: 0, count: 254)]
            catalogue.samples = zip(people, vectors).map { person, vector in
                .init(personID: person.id, embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID, embedding: vector,
                      recordingLocator: f.recording.path, resultID: Self.resultID, turnID: Self.turnID,
                      sourceID: .host, start: 2, end: 7, pcmFingerprint: person.id.uuidString,
                      assignment: .init(personID: person.id, origin: "manual"), policyID: "test")
            }
            catalogue.aggregates = catalogue.samples.map {
                .init(personID: $0.personID, embeddingSpaceID: $0.embeddingSpaceID, centroid: $0.embedding,
                      activeSampleIDs: [$0.id], policyID: "test")
            }
        }
        var next = json
        next["resultID"] = "next"
        let replacement = try JSONSerialization.data(withJSONObject: next)
        let scheduledGeneration = try #require(coordinator.matchingLibraryGeneration)
        if interruption == .changedLibraryBeforeExtraction {
            coordinator.reconcileLibrary(recordings: [], scanComplete: true, id: coordinator.beginLibraryReconciliation())
        }
        let worker = LearningWorker {
            switch interruption {
            case .none, .noCompatibleProfiles: break
            case .changedLibraryBeforeExtraction: Issue.record("Stale scheduled job must not reach the worker")
            case .manualEdit:
                let edit = TranscriptEditsRepository(recordingDirectory: f.recording)
                _ = try edit.saveTurnOverride(resultID: Self.resultID, turnID: nextTurn, text: "Правка", displayName: "Вручную")
            case .newResult:
                let file = writer.resultURL(for: "next")
                let dir = file.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try replacement.write(to: file)
                try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(60)], ofItemAtPath: dir.path)
            case .changeLibrary:
                coordinator.reconcileLibrary(recordings: [], scanComplete: true, id: coordinator.beginLibraryReconciliation())
            case .disableAndEnable:
                coordinator.setEnabled(false)
                coordinator.setEnabled(true)
            case .resetPerson:
                try coordinator.resetPerson(f.oldPerson.id, delete: false)
            }
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.9, margin: 0.1, calendarBonus: 0, maximumAcousticGap: 0))
        let recording = f.recording.appendingPathComponent("meeting_synthetic.m4a")
        if interruption == .noCompatibleProfiles { try coordinator.resetPerson(f.newPerson.id, delete: false) }
        if interruption == .resetPerson {
            await #expect(throws: VoiceProfileCatalogueError.conflict) {
                try await coordinator.automaticallyAssign(recordingURL: recording, resultID: Self.resultID, processing: processing, policy: policy)
            }
        } else if interruption == .newResult {
            await #expect(throws: ProcessingService.VoiceJobError.staleResult) {
                try await coordinator.automaticallyAssign(recordingURL: recording, resultID: Self.resultID, processing: processing, policy: policy)
            }
        } else {
            try await coordinator.automaticallyAssign(recordingURL: recording, resultID: Self.resultID, processing: processing,
                                                     policy: policy, expectedLibraryGeneration: scheduledGeneration)
        }
        let edits = try writer.loadEdits(resultID: Self.resultID)
        #expect(edits.overrides[Self.turnID]?.assignment?.origin == "manual")
        switch interruption {
        case .none:
            #expect(edits.overrides[nextTurn]?.assignment?.personID == f.oldPerson.id)
            #expect(edits.overrides[nextTurn]?.assignment?.origin == "automaticVoiceMatch")
            #expect(edits.pendingLearningEvents == nil)
        case .noCompatibleProfiles:
            #expect(edits.overrides[nextTurn]?.displayName == nil)
            #expect(edits.overrides[nextTurn]?.voiceRefusal == .insufficientProfiles)
            #expect(edits.pendingLearningEvents == nil)
            let textOnly = try writer.saveTurnOverride(resultID: Self.resultID, turnID: nextTurn, text: "Правка", displayName: nil)
            #expect(textOnly.overrides[nextTurn]?.voiceRefusal == .insufficientProfiles)
        case .manualEdit:
            #expect(edits.overrides[nextTurn]?.displayName == "Вручную")
            #expect(edits.overrides[nextTurn]?.text == "Правка")
        case .disableAndEnable, .resetPerson, .newResult, .changeLibrary, .changedLibraryBeforeExtraction:
            #expect(edits.overrides[nextTurn] == nil)
        }
    }

    @Test(arguments: LearningInterruption.allCases)
    func durableLearningCommitRejectsLateFeaturesAfterInvalidation(_ interruption: LearningInterruption) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let result = writer.resultURL(for: Self.resultID)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
        for key in ["words", "baselineWords", "turns"] {
            var items = try #require(json[key] as? [[String: Any]])
            items[0]["end"] = 5.0
            json[key] = items
        }
        try JSONSerialization.data(withJSONObject: json).write(to: result, options: .atomic)
        let document = try TranscriptDocument.load(from: result, recordingDirectory: f.recording)
        let source = try #require(document.sources.first { $0.id == .host })
        let quality = VoiceAudioQuality(resultID: Self.resultID, producer: "test", sources: [
            .init(id: .host, recognitionAudioPath: source.recognitionAudioPath,
                  fingerprint: String(repeating: "a", count: 64), duration: 5, speech: nil, overlap: [])
        ], recordingFingerprint: String(repeating: "c", count: 64))
        let evidence = result.deletingLastPathComponent().appendingPathComponent(VoiceAudioQuality.filename)
        try quality.encoded(for: document).write(to: evidence)
        let edits = try f.correct(using: writer)
        let event = try #require(edits.pendingLearningEvents?.last)
        let worker = LearningWorker {
            switch interruption {
            case .none: break
            case .disableAndEnable:
                coordinator.setEnabled(false)
                coordinator.setEnabled(true)
            case .resetPerson: try coordinator.resetPerson(f.newPerson.id, delete: false)
            }
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8))
        #expect(!coordinator.isEnabled)
        try await coordinator.learn(eventID: event.eventID, writer: writer, processing: processing, policy: policy)
        #expect(try f.catalogue.load().catalogue.samples.isEmpty)

        coordinator.setEnabled(true)
        try await coordinator.learn(eventID: event.eventID, writer: writer, processing: processing, policy: policy)
        let learned = try f.catalogue.load().catalogue
        if interruption == .none {
            #expect(learned.samples.map(\.personID) == [f.newPerson.id])
            #expect(learned.aggregates.isEmpty)
            #expect(learned.learningRecords?.last?.stage == .applied)
            try await coordinator.learn(eventID: event.eventID, writer: writer, processing: processing, policy: policy)
            #expect(try f.catalogue.load().catalogue == learned)
        } else {
            #expect(learned.samples.isEmpty)
        }
        #expect(try writer.loadEdits(resultID: Self.resultID).overrides[Self.turnID]?.assignment?.personID == f.newPerson.id)
    }

    @Test func directWriterCannotChangeLearnedAssignmentWithoutCoordination() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording)
        #expect(throws: TranscriptEditsError.self) {
            try TranscriptSpeakerAssignmentService(editsRepository: writer)
                .assignSpeakerName(resultID: Self.resultID, turnID: Self.turnID, displayName: "Другое имя")
        }
        #expect(try writer.loadEdits(resultID: Self.resultID).overrides[Self.turnID]?.assignment?.personID == f.oldPerson.id)
    }

    @Test func restartAbortsPreparedCorrectionWhenEditsAreUnchanged() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, atomicReplaceHook: { _, _ in
            let staged = try f.catalogue.load().catalogue
            #expect(staged.learningRecords?.map(\.stage) == [.prepared])
            #expect(staged.availableAggregates.isEmpty)
            throw Interrupted.beforeRename
        }, learningCommitObserver: { phase, commit in
            if case .aborted = phase { return }
            coordinator.observe(phase, commit)
        })
        #expect(throws: Interrupted.beforeRename) { try f.correct(using: writer) }
        writer.releaseWriteLock()

        let reopened = TranscriptEditsRepository(recordingDirectory: f.recording)
        try VoiceLearningCoordinator(catalogue: f.catalogue).reconcile(writer: reopened, resultID: Self.resultID)
        let catalogue = try f.catalogue.load().catalogue
        #expect(catalogue.learningRecords?.map(\.stage) == [.aborted])
        #expect(catalogue.availableAggregates.map(\.personID) == [f.oldPerson.id])
        #expect(try reopened.loadEdits(resultID: Self.resultID).overrides[Self.turnID]?.assignment?.personID == f.oldPerson.id)
    }

    @Test func restartTransfersSavedCorrectionWhenAcknowledgementWasLost() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: { phase, commit in
            if case .preparing = phase { coordinator.observe(phase, commit) }
        })
        let saved = try f.correct(using: writer)
        writer.releaseWriteLock()
        #expect(saved.overrides[Self.turnID]?.assignment?.personID == f.newPerson.id)
        #expect(try f.catalogue.load().catalogue.learningRecords?.map(\.stage) == [.prepared])

        let restarted = VoiceLearningCoordinator(catalogue: f.catalogue)
        let reopened = TranscriptEditsRepository(recordingDirectory: f.recording)
        try restarted.reconcile(writer: reopened, resultID: Self.resultID)
        let transferred = try f.catalogue.load().catalogue
        #expect(transferred.learningRecords?.map(\.stage) == [.committed])
        #expect(transferred.samples.isEmpty)
        #expect(transferred.availableAggregates.isEmpty)
        try restarted.reconcile(writer: reopened, resultID: Self.resultID)
        #expect(try f.catalogue.load().catalogue == transferred)
    }

    @Test func failedWriteAheadStillSavesNameAndDurableRevocation() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let dormant = f.root.appendingPathComponent("dormant")
        try FileManager.default.moveItem(at: f.catalogue.directory, to: dormant)
        try FileManager.default.createSymbolicLink(at: f.catalogue.directory, withDestinationURL: dormant)
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let saved = try f.correct(using: writer)
        #expect(saved.overrides[Self.turnID]?.assignment?.personID == f.newPerson.id)
        #expect(coordinator.hasReconciliationFailures)
        #expect(throws: VoiceProfileCatalogueError.unsafePath("VoiceProfiles")) {
            try coordinator.reconcile(writer: writer, resultID: Self.resultID)
        }
        writer.releaseWriteLock()
        try FileManager.default.removeItem(at: f.catalogue.directory)
        try FileManager.default.moveItem(at: dormant, to: f.catalogue.directory)

        let restarted = VoiceLearningCoordinator(catalogue: f.catalogue)
        #expect(!restarted.canMatchVoices)
        let history = RecordingHistoryRepository(voiceLearning: restarted)
        _ = await history.refresh(root: f.root)
        let transferred = try f.catalogue.load().catalogue
        #expect(transferred.learningRecords?.map(\.stage) == [.committed])
        #expect(transferred.samples.isEmpty)
        #expect(restarted.canMatchVoices)
    }

    @Test func correctionStillRevokesPreviouslyLearnedAssignmentWhenDisabled() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let saved = try f.correct(using: writer, learn: false)
        let catalogue = try f.catalogue.load().catalogue
        #expect(saved.overrides[Self.turnID]?.assignment?.personID == f.newPerson.id)
        #expect(catalogue.learningRecords?.map(\.stage) == [.skipped])
        #expect(catalogue.samples.isEmpty)
    }

    @Test func movedFolderReplaysOnlyTheLatestSavedCorrection() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: { phase, commit in
            if case .preparing = phase { coordinator.observe(phase, commit) }
        })
        let first = try f.correct(using: writer)
        let service = TranscriptSpeakerAssignmentService(editsRepository: writer)
        let preview = try service.previewAssignment(resultID: Self.resultID, anchorTurnID: Self.turnID, scope: .single,
            displayName: f.oldPerson.displayName, person: try f.confirmed(f.oldPerson))
        let second = try service.assignSpeakerName(preview: preview, displayName: f.oldPerson.displayName, learnVoice: true)
        writer.releaseWriteLock()
        let moved = f.root.appendingPathComponent("moved")
        try FileManager.default.moveItem(at: f.recording, to: moved)
        let restarted = VoiceLearningCoordinator(catalogue: f.catalogue)
        try restarted.reconcile(writer: TranscriptEditsRepository(recordingDirectory: moved), resultID: Self.resultID)
        let catalogue = try f.catalogue.load().catalogue
        #expect(catalogue.learningRecords?.map(\.stage) == [.superseded, .committed])
        #expect(catalogue.learningRecords?.map(\.recordingLocator) == [moved.path, moved.path])
        #expect(catalogue.learningRecords?.first?.id == first.pendingLearningEvents?.last?.eventID)
        #expect(catalogue.learningRecords?.last?.id == second.pendingLearningEvents?.last?.eventID)
        #expect(catalogue.samples.isEmpty)
    }

    @Test func explicitNewPersonIsCreatedOnlyAfterNameCommitAndBindingsAreDistinct() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let service = TranscriptSpeakerAssignmentService(editsRepository: writer)
        let newID = UUID()
        let person = try coordinator.personSelection(.new(newID), displayName: "Анна")
        let preview = try service.previewAssignment(resultID: Self.resultID, anchorTurnID: Self.turnID, scope: .single,
            displayName: "Анна", person: person)
        #expect(try f.catalogue.load().catalogue.people.map(\.id) == [f.oldPerson.id, f.newPerson.id])
        let saved = try service.assignSpeakerName(preview: preview, displayName: "Анна", learnVoice: false)
        #expect(saved.overrides[Self.turnID]?.assignment?.personID == newID)
        #expect(try f.catalogue.load().catalogue.people.map(\.id) == [f.oldPerson.id, f.newPerson.id, newID])

        let contextURL = f.recording.appendingPathComponent("meeting_synthetic.context.json")
        let context = Data(#"{"summary":"Synthetic","attendees":["Анна","Анна"],"calendarParticipants":[{"displayName":"Анна","address":"one@example.invalid"},{"displayName":"Анна","address":"two@example.invalid"}]}"#.utf8)
        try context.write(to: contextURL)
        let document = try TranscriptDocument.load(from: writer.resultURL(for: Self.resultID), recordingDirectory: f.recording)
        #expect(try f.catalogue.load().catalogue.people.allSatisfy { $0.calendarBindings.isEmpty })
        try coordinator.confirmCalendarBinding(personID: newID, address: "two@example.invalid", in: document)
        #expect(throws: TranscriptEditsError.self) {
            try coordinator.confirmCalendarBinding(personID: f.oldPerson.id, address: "two@example.invalid", in: document)
        }
        #expect(throws: TranscriptEditsError.self) {
            try coordinator.confirmCalendarBinding(personID: f.newPerson.id, address: "Анна", in: document)
        }
        let people = try f.catalogue.load().catalogue.people
        #expect(people.filter { !$0.calendarBindings.isEmpty }.map(\.id) == [newID])
        #expect(people.last?.calendarBindings == ["two@example.invalid"])
    }

    @Test(arguments: [false, true])
    func replayCannotRecreateADeletedPersonOrCatalogue(deleteAll: Bool) throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let service = TranscriptSpeakerAssignmentService(editsRepository: writer)
        let id = UUID()
        let person = try coordinator.personSelection(.new(id), displayName: "Анна")
        let preview = try service.previewAssignment(resultID: Self.resultID, anchorTurnID: Self.turnID, scope: .single,
            displayName: "Анна", person: person)
        _ = try service.assignSpeakerName(preview: preview, displayName: "Анна", learnVoice: true)
        writer.releaseWriteLock()
        #expect(try f.catalogue.load().catalogue.learningRecords?.last?.stage == .committed)
        if deleteAll { try coordinator.deleteCatalogue() }
        else { try coordinator.resetPerson(id, delete: true) }
        let reopened = TranscriptEditsRepository(recordingDirectory: f.recording)
        try VoiceLearningCoordinator(catalogue: f.catalogue).reconcile(writer: reopened, resultID: Self.resultID)
        let value = try f.catalogue.load().catalogue
        #expect(!value.people.contains { $0.id == id })
        #expect(value.learningRecords?.last?.stage == .skipped)
        #expect(try reopened.loadEdits(resultID: Self.resultID).overrides[Self.turnID]?.assignment?.personID == id)
    }

    @Test func trashPreservesPendingRevocationWithoutAudio() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let recording = f.recording.appendingPathComponent("meeting_synthetic.m4a")
        let destination = f.root.appendingPathComponent("moved-out")
        let dormant = f.root.appendingPathComponent("dormant")
        try Data().write(to: recording)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: { _, _ in })
        _ = try f.correct(using: writer)
        writer.releaseWriteLock()
        let currentID = "res_new_current"
        let current = writer.resultURL(for: currentID)
        let original = writer.resultURL(for: Self.resultID)
        let originalData = try Data(contentsOf: original)
        let newer = String(decoding: originalData, as: UTF8.self).replacingOccurrences(of: Self.resultID, with: currentID)
        try FileManager.default.createDirectory(at: current.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(newer.utf8).write(to: current)
        try FileManager.default.setAttributes([.creationDate: Date().addingTimeInterval(10)],
                                             ofItemAtPath: current.deletingLastPathComponent().path)
        #expect(try TranscriptResultStorage(recordingURL: recording).currentResultDirectory()?.lastPathComponent == currentID)
        let history = RecordingHistoryRepository(voiceLearning: VoiceLearningCoordinator(catalogue: f.catalogue))
        history.put(RecordingEntry(recording: recording, date: Date(), title: "Синтетика", phase: .completed))
        try FileManager.default.moveItem(at: f.catalogue.directory, to: dormant)
        try FileManager.default.createSymbolicLink(at: f.catalogue.directory, withDestinationURL: dormant)
        let target = try history.prepareTrash(recording, root: f.root)
        let rejected = try history.reserveTrash(target)
        #expect(throws: RecordingTrashFailure.self) {
            try history.trash(target, reservation: rejected) { _ in
                Issue.record("Moved source before saving the revocation")
            }
        }
        #expect(FileManager.default.fileExists(atPath: recording.path))
        try FileManager.default.removeItem(at: f.catalogue.directory)
        try FileManager.default.moveItem(at: dormant, to: f.catalogue.directory)

        let accepted = try history.reserveTrash(target)
        _ = try history.trash(target, reservation: accepted) { source in
            #expect(try f.catalogue.load().catalogue.samples.isEmpty)
            try FileManager.default.moveItem(at: source, to: destination)
        }
        #expect(!FileManager.default.fileExists(atPath: recording.path))
        let catalogue = try f.catalogue.load().catalogue
        #expect(catalogue.learningRecords?.map(\.stage) == [.committed])
        #expect(catalogue.availableAggregates.isEmpty)
    }

    @Test func failedCASDoesNotSuspendAProfileAfterAnotherEdit() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, atomicReplaceHook: { _, destination in
            var edits = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination)) as? [String: Any])
            var overrides = try #require(edits["overrides"] as? [String: [String: Any]])
            overrides[Self.turnID]?["text"] = "Конкурентная правка"
            edits["overrides"] = overrides
            try JSONSerialization.data(withJSONObject: edits).write(to: destination, options: .atomic)
        }, learningCommitObserver: coordinator.observe)
        #expect(throws: TranscriptEditsError.self) { try f.correct(using: writer) }
        writer.releaseWriteLock()
        let reopened = TranscriptEditsRepository(recordingDirectory: f.recording)
        try VoiceLearningCoordinator(catalogue: f.catalogue).reconcile(writer: reopened, resultID: Self.resultID)
        let value = try f.catalogue.load().catalogue
        #expect(value.learningRecords?.map(\.stage) == [.aborted])
        #expect(value.availableAggregates.map(\.personID) == [f.oldPerson.id])
        #expect(try reopened.loadEdits(resultID: Self.resultID).overrides[Self.turnID]?.text == "Конкурентная правка")
    }

    @Test func laterSavedAssignmentResolvesFailedCASSuspensionEvenWhenAbortWasLost() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, atomicReplaceHook: { _, destination in
            var bytes = try Data(contentsOf: destination)
            bytes.append(10)
            try bytes.write(to: destination, options: .atomic)
        }, learningCommitObserver: { phase, commit in
            if case .preparing = phase { coordinator.observe(phase, commit) }
        })
        #expect(throws: TranscriptEditsError.self) { try f.correct(using: writer) }
        #expect(try f.catalogue.load().catalogue.learningRecords?.map(\.stage) == [.prepared])
        writer.releaseWriteLock()
        let reopened = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        _ = try f.correct(using: reopened)
        try coordinator.reconcile(writer: reopened, resultID: Self.resultID)
        #expect(try f.catalogue.load().catalogue.learningRecords?.map(\.stage) == [.aborted, .committed])
    }

    @Test func anUnavailableLibraryRootKeepsMatchingBlocked() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let history = RecordingHistoryRepository(voiceLearning: coordinator)
        _ = await history.refresh(root: f.root.appendingPathComponent("offline-library"), allowMissingRoot: true)
        #expect(!coordinator.canMatchVoices)
        _ = await history.refresh(root: f.root)
        #expect(coordinator.canMatchVoices)
    }

    @Test func successfulTransferClearsAFailedWriteAheadImmediately() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let history = RecordingHistoryRepository(voiceLearning: coordinator)
        _ = await history.refresh(root: f.root)
        #expect(coordinator.canMatchVoices)
        let descriptor = open(f.catalogue.directory.appendingPathComponent("catalogue.lock").path, O_RDWR | O_CLOEXEC)
        try #require(descriptor >= 0)
        defer { close(descriptor) }
        try #require(flock(descriptor, LOCK_EX | LOCK_NB) == 0)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, atomicReplaceHook: { _, _ in
            #expect(!coordinator.canMatchVoices)
            #expect(flock(descriptor, LOCK_UN) == 0)
        }, learningCommitObserver: coordinator.observe)
        _ = try f.correct(using: writer)
        #expect(coordinator.canMatchVoices)
        #expect(try f.catalogue.load().catalogue.learningRecords?.map(\.stage) == [.committed])
    }

    @Test func outboxCannotRecreateAPersonAfterCatalogueFileWasRemoved() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: { _, _ in })
        let service = TranscriptSpeakerAssignmentService(editsRepository: writer)
        let person = try coordinator.personSelection(.new(UUID()), displayName: "Анна")
        let preview = try service.previewAssignment(resultID: Self.resultID, anchorTurnID: Self.turnID, scope: .single,
            displayName: "Анна", person: person)
        _ = try service.assignSpeakerName(preview: preview, displayName: "Анна", learnVoice: true)
        try FileManager.default.removeItem(at: f.catalogue.directory.appendingPathComponent("catalogue.json"))

        try VoiceLearningCoordinator(catalogue: f.catalogue).reconcile(writer: writer, resultID: Self.resultID)
        let value = try f.catalogue.load().catalogue
        #expect(value.people.isEmpty)
        #expect(value.learningRecords?.map(\.stage) == [.skipped])
    }

    @Test func personalResetRejectsAnEarlierSelectionAndClearsCalendarBinding() throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let service = TranscriptSpeakerAssignmentService(editsRepository: writer)
        _ = try f.catalogue.update(f.catalogue.load()) {
            $0.people[1].calendarBindings = ["contact@example.invalid"]
        }
        let person = try coordinator.personSelection(.existing(f.newPerson.id), displayName: "Анна")
        let preview = try service.previewAssignment(resultID: Self.resultID, anchorTurnID: Self.turnID, scope: .single,
            displayName: "Анна", person: person)
        try coordinator.resetPerson(f.newPerson.id, delete: false)
        let saved = try service.assignSpeakerName(preview: preview, displayName: "Анна", learnVoice: true)
        #expect(saved.overrides[Self.turnID]?.assignment?.personID == f.newPerson.id)
        let value = try f.catalogue.load().catalogue
        #expect(value.learningRecords?.map(\.stage) == [.skipped])
        #expect(value.people.first(where: { $0.id == f.newPerson.id })?.calendarBindings.isEmpty == true)

        let rawID = try service.previewAssignment(resultID: Self.resultID, anchorTurnID: Self.turnID, scope: .single,
            displayName: "Анна", person: .explicit(f.oldPerson.id))
        let raw = try service.assignSpeakerName(preview: rawID, displayName: "Анна", learnVoice: true)
        #expect(raw.pendingLearningEvents?.last?.allowsLearning == false)
    }

    @Test func learningUsesOtherCleanWindowsWhenDenseSpeechDoesNotFillLimit() async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        coordinator.setEnabled(true)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let result = writer.resultURL(for: Self.resultID)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])
        let intervals = [(1.0, 5.0), (6, 10), (11, 15)]
        let words = zip(intervals, ["Я сейчас проверю статус этой задачи", "Одну минуту", "Дальше"]).enumerated().map { index, item in
            ["id": "w_\(index)", "speakerID": "spk_h1", "start": item.0.0, "end": item.0.1, "text": item.1] as [String: Any]
        }
        json["words"] = words
        json["baselineWords"] = words
        json["turns"] = [["id": Self.turnID, "speakerID": "spk_h1", "start": 0, "end": 16,
                           "wordIDs": ["w_0", "w_1", "w_2"]]]
        try JSONSerialization.data(withJSONObject: json).write(to: result)
        let document = try TranscriptDocument.load(from: result, recordingDirectory: f.recording)
        let quality = VoiceAudioQuality(resultID: Self.resultID, producer: "test", sources: document.sources.map { source in
            .init(id: source.id, recognitionAudioPath: source.recognitionAudioPath,
                  fingerprint: String(repeating: "a", count: 64), duration: 16,
                  speech: source.id == .host ? intervals.map { .init(start: $0.0, end: $0.1) } : nil, overlap: [])
        }, recordingFingerprint: String(repeating: "c", count: 64))
        try quality.encoded(for: document).write(to: result.deletingLastPathComponent().appendingPathComponent(VoiceAudioQuality.filename))
        let saved = try f.correct(using: writer)
        let event = try #require(saved.pendingLearningEvents?.last)
        let worker = LearningWorker {}
        let service = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let extracted = try await coordinator.learn(eventID: event.eventID, writer: writer, processing: service,
                                                    policy: try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8)))
        #expect(extracted == 3)
    }

    @Test(arguments: [false, true])
    func bulkLearningPrefersDenseWindowsAcrossTurns(mixedFirstTurn: Bool) async throws {
        let f = try Fixture()
        defer { try? FileManager.default.removeItem(at: f.root) }
        let coordinator = VoiceLearningCoordinator(catalogue: f.catalogue)
        coordinator.setEnabled(true)
        let writer = TranscriptEditsRepository(recordingDirectory: f.recording, learningCommitObserver: coordinator.observe)
        let result = writer.resultURL(for: Self.resultID)
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result)) as? [String: Any])

        var words: [[String: Any]] = [
            ["id": "w_sparse", "speakerID": "spk_h1", "start": 0.0, "end": 12.0, "text": "Привет."]
        ]
        var turns: [[String: Any]] = [
            ["id": Self.turnID, "speakerID": "spk_h1", "start": 0.0, "end": 12.0, "wordIDs": ["w_sparse"]]
        ]
        let firstTurnSpeech = [(1.0, 5.0), (6.0, 10.0), (11.0, 15.0)]
        if mixedFirstTurn {
            words = zip(firstTurnSpeech, ["Я сейчас проверю статус этой задачи", "Одну минуту", "Дальше"])
                .enumerated().map { index, item in
                    ["id": "w_first_\(index)", "speakerID": "spk_h1", "start": item.0.0, "end": item.0.1, "text": item.1]
                }
            turns = [["id": Self.turnID, "speakerID": "spk_h1", "start": 0.0, "end": 16.0, "wordIDs": words.compactMap { $0["id"] as? String }]]
        }
        let denseTurnCount = mixedFirstTurn ? 3 : 4
        for idx in 1...denseTurnCount {
            let tStart = Double((idx + 1) * 10)
            var wids: [String] = []
            for w in 0..<8 {
                let wid = "w_\(idx)_\(w)"
                words.append(["id": wid, "speakerID": "spk_h1", "start": tStart + Double(w) * 0.75, "end": tStart + Double(w) * 0.75 + 0.7, "text": "слово"])
                wids.append(wid)
            }
            turns.append(["id": "turn_\(idx + 1)", "speakerID": "spk_h1", "start": tStart, "end": tStart + 6.0, "wordIDs": wids])
        }
        json["words"] = words
        json["baselineWords"] = words
        json["turns"] = turns
        try JSONSerialization.data(withJSONObject: json).write(to: result)
        try Data("synthetic-host".utf8).write(to: f.recording.appendingPathComponent("raw/meeting.host_record.wav"))
        try Data("synthetic-remote".utf8).write(to: f.recording.appendingPathComponent("raw/meeting.remote_record.wav"))
        if mixedFirstTurn {
            let document = try TranscriptDocument.load(from: result, recordingDirectory: f.recording)
            let source = try #require(document.sources.first { $0.id == .host })
            let hostSpeech = firstTurnSpeech + (1...denseTurnCount).map {
                let start = Double(($0 + 1) * 10)
                return (start, start + 6)
            }
            let quality = VoiceAudioQuality(resultID: Self.resultID, producer: "test", sources: [
                .init(id: .host, recognitionAudioPath: source.recognitionAudioPath,
                      fingerprint: String(repeating: "a", count: 64), duration: 46,
                      speech: hostSpeech.map { .init(start: $0.0, end: $0.1) }, overlap: [])
            ], recordingFingerprint: String(repeating: "c", count: 64))
            try quality.encoded(for: document).write(to: result.deletingLastPathComponent().appendingPathComponent(VoiceAudioQuality.filename))
        }

        let service = TranscriptSpeakerAssignmentService(editsRepository: writer)
        let preview = try service.previewAssignment(resultID: Self.resultID, anchorTurnID: Self.turnID,
            scope: .group, displayName: f.newPerson.displayName, person: try f.confirmed(f.newPerson), replaceManuallyAssigned: true)
        let edits = try service.assignSpeakerName(preview: preview, displayName: f.newPerson.displayName, learnVoice: true)

        let capturedStarts = Mutex<[Int]>([])
        struct CaptureWorker: TranscriptionRunnerProtocol, VoiceEmbeddingRunnerProtocol, AudioExporterProtocol {
            let onWindow: @Sendable (Int) -> Void
            func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool, onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) {
                throw TranscriptEditsError.notImplemented
            }
            func run(recording: URL, parakeet: Bool, echoCancellation: Bool, onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
                throw TranscriptEditsError.notImplemented
            }
            func exportMixedAudio(from inputs: [URL], to output: URL) async throws {
                throw TranscriptEditsError.notImplemented
            }
            func extractVoiceEmbeddings(_ request: VoiceEmbeddingProtocol.Request, recordingDirectory: URL) async throws -> VoiceEmbeddingProtocol.Response {
                for window in request.windows { onWindow(window.startFrame) }
                return .init(requestID: request.id, features: request.windows.map {
                    .init(windowID: $0.id, pcmFingerprint: String(repeating: "b", count: 64),
                          embedding: [Float(1)] + Array(repeating: 0, count: 255))
                })
            }
        }
        let worker = CaptureWorker { startFrame in
            capturedStarts.withLock { $0.append(startFrame) }
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        await coordinator.learnCommitted(events: try #require(edits.pendingLearningEvents), writer: writer, processing: processing,
            policy: try #require(VoiceProfileUpdatePolicy(id: "test", minimumAgreement: 0.8)),
            expectedGeneration: try #require(coordinator.featureGeneration))

        let starts = capturedStarts.withLock { $0 }
        #expect(starts.count == 4)
        #expect(starts.allSatisfy { $0 >= 20 * 16_000 || (mixedFirstTurn && $0 == 16_000) })
    }
}

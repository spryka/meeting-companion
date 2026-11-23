import Foundation
@testable import MeetingCompanionApplication
@testable import MeetingCompanionCore
import Synchronization
import Testing

private struct MockAutoAssignWorker: TranscriptionRunnerProtocol, VoiceEmbeddingRunnerProtocol, AudioExporterProtocol {
    let handler: @Sendable (VoiceEmbeddingProtocol.Request) throws -> VoiceEmbeddingProtocol.Response

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
        try handler(request)
    }
}

@Suite struct VoiceAutomaticAssignmentTests {
    private let vecA: [Float] = [1, 0, 0] + Array(repeating: 0, count: 253)
    private let vecB: [Float] = [0, 1, 0] + Array(repeating: 0, count: 253)
    private let vecC: [Float] = [0, 0, 1] + Array(repeating: 0, count: 253)
    private let vecWeak: [Float] = [0.5, 0, 0, 0.8660254] + Array(repeating: 0, count: 252)

    private struct Env {
        let root: URL
        let recordingDir: URL
        let recordingURL: URL
        let resultID = "res_auto_test"
        let catalogue: VoiceProfileCatalogueRepository
        let writer: TranscriptEditsRepository
        let coordinator: VoiceLearningCoordinator
        let personA = VoiceProfilePerson(displayName: "Анна")
        let personB = VoiceProfilePerson(displayName: "Илья")
        let personC = VoiceProfilePerson(displayName: "Сергей")

        init(vecA: [Float], vecB: [Float], vecC: [Float]) throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("voice-auto-\(UUID().uuidString)", isDirectory: true)
            recordingDir = root.appendingPathComponent("meeting_auto", isDirectory: true)
            recordingURL = recordingDir.appendingPathComponent("meeting_auto.m4a")
            catalogue = VoiceProfileCatalogueRepository(applicationDataDirectory: root)
            writer = TranscriptEditsRepository(recordingDirectory: recordingDir)
            coordinator = VoiceLearningCoordinator(catalogue: catalogue)
            coordinator.setEnabled(true)
            coordinator.reconcileLibrary(recordings: [], scanComplete: true, id: coordinator.beginLibraryReconciliation())

            try FileManager.default.createDirectory(
                at: recordingDir.appendingPathComponent("raw/transcripts/\(resultID)"), withIntermediateDirectories: true)
            try Data("synthetic-host".utf8).write(to: recordingDir.appendingPathComponent("raw/host.wav"))
            try Data("synthetic-remote".utf8).write(to: recordingDir.appendingPathComponent("raw/remote.wav"))

            _ = try catalogue.update(catalogue.load()) { value in
                value.people = [personA, personB, personC]
                for (person, vec) in [(personA, vecA), (personB, vecB), (personC, vecC)] {
                    let s = VoiceProfileSample(
                        personID: person.id, embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID,
                        embedding: vec, recordingLocator: recordingDir.path, resultID: "seed", turnID: "seed",
                        sourceID: .host, start: 0, end: 4, pcmFingerprint: "pcm-\(person.id.uuidString)",
                        assignment: .init(personID: person.id, origin: "manual"), policyID: "test")
                    value.samples.append(s)
                    value.aggregates.append(.init(
                        personID: person.id, embeddingSpaceID: VoiceEmbeddingProtocol.embeddingSpaceID,
                        centroid: vec, activeSampleIDs: [s.id], policyID: "test"))
                }
            }
        }

        func cleanup() { try? FileManager.default.removeItem(at: root) }

        func writeDocument(
            speakers: [TranscriptDocument.Speaker],
            turns specs: [(id: String, speakerID: String, start: Double, end: Double)],
            includeQuality: Bool = true,
            hostDiarization: (status: TranscriptDocument.ProcessingStatus, voices: Int?) = (.completed, 2),
            remoteDiarization: (status: TranscriptDocument.ProcessingStatus, voices: Int?) = (.completed, 2),
            calendarParticipants: [TranscriptDocument.CalendarParticipant]? = nil
        ) throws {
            let sources: [TranscriptDocument.Source] = [
                .init(id: .host, originalAudioPath: "raw/host.wav", recognitionAudioPath: "raw/host.wav",
                      diarizationStatus: hostDiarization.status, detectedVoiceCount: hostDiarization.voices, correctionStatus: .disabled),
                .init(id: .remote, originalAudioPath: "raw/remote.wav", recognitionAudioPath: "raw/remote.wav",
                      diarizationStatus: remoteDiarization.status, detectedVoiceCount: remoteDiarization.voices, correctionStatus: .disabled)
            ]
            var words: [TranscriptDocument.Word] = []
            var turns: [TranscriptDocument.Turn] = []
            for spec in specs {
                let wid = "w_\(spec.id)"
                words.append(.init(id: wid, speakerID: spec.speakerID, start: spec.start, end: spec.end, text: "Текст"))
                turns.append(.init(id: spec.id, speakerID: spec.speakerID, start: spec.start, end: spec.end, wordIDs: [wid]))
            }
            let context = calendarParticipants.map {
                TranscriptDocument.Context(title: "Синтетика", calendarParticipants: $0)
            }
            let doc = try TranscriptDocument(
                schemaVersion: 1, resultID: resultID, createdAt: "2026-11-21T12:00:00Z",
                sources: sources, speakers: speakers, words: words, turns: turns, baselineWords: words,
                aec: .init(requested: false, outcome: .disabled),
                playback: .init(status: .unavailable, mixPath: nil),
                warnings: [.init(code: "test", message: "synthetic")],
                context: context)
            let resultDir = recordingDir.appendingPathComponent("raw/transcripts/\(resultID)")
            try JSONEncoder().encode(doc).write(to: resultDir.appendingPathComponent("result.json"))

            if includeQuality {
                let maxEnd = (specs.map(\.end).max() ?? 10) + 5
                let quality = VoiceAudioQuality(
                    resultID: resultID, producer: "test",
                    sources: [
                        .init(id: .host, recognitionAudioPath: "raw/host.wav",
                              fingerprint: String(repeating: "a", count: 64),
                              duration: maxEnd, speech: [.init(start: 0, end: maxEnd)], overlap: []),
                        .init(id: .remote, recognitionAudioPath: "raw/remote.wav",
                              fingerprint: String(repeating: "b", count: 64),
                              duration: maxEnd, speech: [.init(start: 0, end: maxEnd)], overlap: [])
                    ],
                    recordingFingerprint: String(repeating: "c", count: 64))
                try quality.encoded(for: doc).write(to: resultDir.appendingPathComponent(VoiceAudioQuality.filename))
            }
        }
    }

    @Test func groupMatchesShortAndSingleBlockTurnsWhilePreservingManualEdits() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        // All 3 clean turns are concentrated in [0, 30] (same first third of [0, 200]), plus short <3s turns at 100s and 199s.
        try env.writeDocument(speakers: [sp1], turns: [
            ("t1", "sp1", 0, 5),
            ("t2", "sp1", 10, 15),
            ("t3", "sp1", 20, 25),
            ("t_manual", "sp1", 30, 35),
            ("t_short1", "sp1", 100, 101.2),
            ("t_short2", "sp1", 199, 200.0)
        ])
        _ = try env.writer.saveTurnOverride(resultID: env.resultID, turnID: "t_manual", text: nil, displayName: "Своё имя")
        env.writer.releaseWriteLock()

        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        #expect(edits.overrides["t_manual"]?.displayName == "Своё имя")
        #expect(edits.overrides["t_manual"]?.assignment?.origin == "manual")
        for turnID in ["t1", "t2", "t3", "t_short1", "t_short2"] {
            #expect(edits.overrides[turnID]?.displayName == env.personA.displayName)
            #expect(edits.overrides[turnID]?.assignment?.personID == env.personA.id)
            #expect(edits.overrides[turnID]?.assignment?.origin == "automaticVoiceMatch")
        }
        #expect(edits.pendingLearningEvents == nil)
    }

    @Test func mixedClusterWithSecondStrongLeaderRefusesEntireGroupAsAmbiguous() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .remote, localID: 1, displayNumber: 2)
        try env.writeDocument(speakers: [sp1], turns: [
            ("t1", "sp1", 0, 5),
            ("t2", "sp1", 10, 15),
            ("t3", "sp1", 20, 25),
            ("t4", "sp1", 30, 35),
            ("t_short", "sp1", 40, 41.5)
        ])
        // Strong leader B without margin: cos(B)=0.70 >= 0.60, cos(A)=0.65 -> gap=0.05 < margin(0.15), NOT a match for B,
        // yet strongLeaders includes BOTH A and B!
        let mixedVec: [Float] = [0.65, 0.70, 0.295804] + Array(repeating: 0, count: 253)
        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.enumerated().map { idx, win in
                .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64),
                      embedding: idx == 3 ? mixedVec : vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        for turnID in ["t1", "t2", "t3", "t4", "t_short"] {
            #expect(edits.overrides[turnID]?.displayName == nil)
            #expect(edits.overrides[turnID]?.voiceRefusal == .ambiguous)
        }
    }

    @Test func nilEmbeddingsCountInGroupDenominatorAndRejectInsufficientMatches() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        // 3 windows: 2 match A, 1 returns nil -> 2/3 < minimum 3 matches -> must NOT assign!
        try env.writeDocument(speakers: [sp1], turns: [
            ("t1", "sp1", 0, 5),
            ("t2", "sp1", 10, 15),
            ("t3", "sp1", 20, 25),
            ("t_short", "sp1", 30, 31)
        ])
        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.enumerated().map { idx, win in
                .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64),
                      embedding: idx == 2 ? nil : vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        for turnID in ["t1", "t2", "t3", "t_short"] {
            #expect(edits.overrides[turnID]?.displayName == nil)
        }
        #expect(edits.overrides["t3"]?.voiceRefusal == .insufficientSpeech)
    }

    @Test func quotaLimitsBatchTo64WindowsWhileAssigningSkippedTurnsInMatchedGroups() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        let sp2 = TranscriptDocument.Speaker(id: "sp2", sourceID: .remote, localID: 1, displayNumber: 2)
        // 10 clean turns for sp1 + 90 clean turns for sp2 = 100 clean turns.
        var specs: [(String, String, Double, Double)] = []
        for i in 0..<10 {
            specs.append(("h\(i)", "sp1", Double(i * 10), Double(i * 10 + 5)))
        }
        for i in 0..<90 {
            specs.append(("r\(i)", "sp2", Double(i * 10), Double(i * 10 + 5)))
        }
        try env.writeDocument(speakers: [sp1, sp2], turns: specs)

        let batchCounts = Mutex<[Int]>([])
        let worker = MockAutoAssignWorker { req in
            batchCounts.withLock { $0.append(req.windows.count) }
            return .init(requestID: req.id, features: req.windows.map { win in
                let emb = win.sourceID == .host ? vecA : vecB
                return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: emb)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        #expect(batchCounts.withLock { $0 } == [64])
        let edits = try env.writer.loadEdits(resultID: env.resultID)
        for i in 0..<10 {
            #expect(edits.overrides["h\(i)"]?.assignment?.personID == env.personA.id)
        }
        for i in 0..<90 {
            #expect(edits.overrides["r\(i)"]?.assignment?.personID == env.personB.id)
        }
    }

    @Test func missingVoiceQualityFileUsesDocumentWordsFallbackEndToEnd() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        try env.writeDocument(speakers: [sp1], turns: [
            ("t1", "sp1", 0, 5),
            ("t2", "sp1", 10, 15),
            ("t3", "sp1", 20, 25),
            ("t_short", "sp1", 30, 31)
        ], includeQuality: false)

        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        for turnID in ["t1", "t2", "t3", "t_short"] {
            #expect(edits.overrides[turnID]?.assignment?.personID == env.personA.id)
        }
    }

    @Test func smallAndLargeGroupThresholdsAreEnforcedExactly() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        // sp1 (1/1 -> pass), sp2 (1/2 -> fail), sp3 (2/3 -> fail: matchedCount < 3), sp4 (3/4 -> pass: 3/4 >= 2/3)
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        let sp2 = TranscriptDocument.Speaker(id: "sp2", sourceID: .host, localID: 2, displayNumber: 2)
        let sp3 = TranscriptDocument.Speaker(id: "sp3", sourceID: .remote, localID: 1, displayNumber: 3)
        let sp4 = TranscriptDocument.Speaker(id: "sp4", sourceID: .remote, localID: 2, displayNumber: 4)
        try env.writeDocument(speakers: [sp1, sp2, sp3, sp4], turns: [
            ("s1_1", "sp1", 0, 5), ("s1_short", "sp1", 6, 7),
            ("s2_1", "sp2", 10, 15), ("s2_2", "sp2", 20, 25),
            ("s3_1", "sp3", 0, 5), ("s3_2", "sp3", 10, 15), ("s3_3", "sp3", 20, 25),
            ("s4_1", "sp4", 30, 35), ("s4_2", "sp4", 40, 45), ("s4_3", "sp4", 50, 55), ("s4_4", "sp4", 60, 65)
        ])
        let weakByStart: Set<Int> = [20 * 16_000, 60 * 16_000] // s2_2 (20s), s3_3 (20s), s4_4 (60s)
        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.map { win in
                let isWeak = weakByStart.contains { abs(win.startFrame - $0) < 16_000 }
                return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64),
                             embedding: isWeak ? vecWeak : (win.sourceID == .host ? vecA : vecB))
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        #expect(edits.overrides["s1_1"]?.assignment?.personID == env.personA.id)
        #expect(edits.overrides["s1_short"]?.assignment?.personID == env.personA.id)
        #expect(edits.overrides["s2_1"]?.displayName == nil)
        #expect(edits.overrides["s2_2"]?.displayName == nil)
        #expect(edits.overrides["s3_1"]?.displayName == nil)
        #expect(edits.overrides["s3_2"]?.displayName == nil)
        #expect(edits.overrides["s3_3"]?.displayName == nil)
        for id in ["s4_1", "s4_2", "s4_3", "s4_4"] {
            #expect(edits.overrides[id]?.assignment?.personID == env.personB.id)
        }
    }

    @Test func watershedQuotaGivesSmallGroupsAllWindowsAndSamplesLargeGroupsEvenlyWithoutRefusal() throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        let sp2 = TranscriptDocument.Speaker(id: "sp2", sourceID: .host, localID: 2, displayNumber: 2)
        let sp3 = TranscriptDocument.Speaker(id: "sp3", sourceID: .remote, localID: 1, displayNumber: 3)
        let sp4 = TranscriptDocument.Speaker(id: "sp4", sourceID: .remote, localID: 2, displayNumber: 4)

        var specs: [(String, String, Double, Double)] = []
        for i in 0..<4 { specs.append(("a\(i)", "sp1", Double(i * 10), Double(i * 10 + 5))) }
        for i in 0..<6 { specs.append(("b\(i)", "sp2", Double(50 + i * 10), Double(50 + i * 10 + 5))) }
        for i in 0..<45 { specs.append(("c\(i)", "sp3", Double(i * 10), Double(i * 10 + 5))) }
        for i in 0..<45 { specs.append(("d\(i)", "sp4", Double(500 + i * 10), Double(500 + i * 10 + 5))) }
        try env.writeDocument(speakers: [sp1, sp2, sp3, sp4], turns: specs)

        let resultDir = env.recordingDir.appendingPathComponent("raw/transcripts/\(env.resultID)")
        let doc = try TranscriptDocument.load(from: resultDir.appendingPathComponent("result.json"), recordingDirectory: env.recordingDir)
        let quality = try VoiceAudioQuality.load(in: resultDir, for: doc)
        let edits = try env.writer.loadEdits(resultID: env.resultID)

        let plan = try VoiceAutomaticAssignment.plan(document: doc, edits: edits, quality: quality, hasProfiles: true)
        #expect(plan.queries.count == 64)
        #expect(plan.refusals.isEmpty)

        let bySpeaker = Dictionary(grouping: plan.queries, by: \.turn.speakerID)
        #expect(bySpeaker["sp1"]?.count == 4)
        #expect(bySpeaker["sp2"]?.count == 6)
        #expect(bySpeaker["sp3"]?.count == 27)
        #expect(bySpeaker["sp4"]?.count == 27)
        #expect(bySpeaker["sp3"]?.first?.turn.id == "c0")
        #expect(bySpeaker["sp3"]?.last?.turn.id == "c44")
        #expect(bySpeaker["sp4"]?.first?.turn.id == "d0")
        #expect(bySpeaker["sp4"]?.last?.turn.id == "d44")
    }

    @Test func calendarBonusCannotHideSecondAcousticLeaderInGroup() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        _ = try env.catalogue.update(env.catalogue.load()) { value in
            value.people[0].calendarBindings = ["anna@example.invalid"]
        }
        let contactURL = try #require(URL(string: "mailto:anna@example.invalid"))
        let participant = try #require(TranscriptDocument.CalendarParticipant(displayName: "Анна", contactURL: contactURL))
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        try env.writeDocument(speakers: [sp1], turns: [
            ("t1", "sp1", 0, 5), ("t2", "sp1", 10, 15), ("t3", "sp1", 20, 25), ("t4", "sp1", 30, 35),
            ("t_short", "sp1", 40, 41)
        ], calendarParticipants: [participant])
        let boostedMixed: [Float] = [0.65, 0.70, 0.295804] + Array(repeating: 0, count: 253)
        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.enumerated().map { idx, win in
                .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64),
                      embedding: idx == 3 ? boostedMixed : vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0.25, maximumAcousticGap: 0.1))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        for turnID in ["t1", "t2", "t3", "t4", "t_short"] {
            #expect(edits.overrides[turnID]?.displayName == nil)
            #expect(edits.overrides[turnID]?.voiceRefusal == .ambiguous)
        }
    }

    @Test func undiarizedSourceRefusesWithMissingEvidenceInsteadOfGroupingFallbackLabels() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        let sp2 = TranscriptDocument.Speaker(id: "sp2", sourceID: .remote, localID: 1, displayNumber: 2)
        try env.writeDocument(
            speakers: [sp1, sp2],
            turns: [("h1", "sp1", 0, 6), ("h_short", "sp1", 7, 8), ("r1", "sp2", 0, 6)],
            includeQuality: false,
            hostDiarization: (.failed, nil),
            remoteDiarization: (.completed, 0)
        )
        let calls = Mutex(0)
        let worker = MockAutoAssignWorker { req in
            calls.withLock { $0 += 1 }
            return .init(requestID: req.id, features: req.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        #expect(calls.withLock { $0 } == 0)
        let edits = try env.writer.loadEdits(resultID: env.resultID)
        for id in ["h1", "h_short", "r1"] {
            #expect(edits.overrides[id]?.displayName == nil)
            #expect(edits.overrides[id]?.voiceRefusal == .missingEvidence)
        }
    }

    @Test func exact96000FrameWindowAcceptsFloatDriftAtSixSecondsBoundary() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        // [0, 10.1] -> trimmed [0.15, 9.95] -> centered 96_000 frames [32_800, 128_800] -> [2.05, 8.05]
        // where 8.05 - 2.05 == 6.000000000000001 in Double.
        try env.writeDocument(speakers: [sp1], turns: [("t1", "sp1", 0, 10.1), ("t_short", "sp1", 11, 12)])
        let worker = MockAutoAssignWorker { req in
            #expect(req.windows.count == 1)
            #expect(req.windows[0].endFrame - req.windows[0].startFrame == 96_000)
            return .init(requestID: req.id, features: req.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        #expect(edits.overrides["t1"]?.assignment?.personID == env.personA.id)
        #expect(edits.overrides["t_short"]?.assignment?.personID == env.personA.id)
    }

    @Test func timeBasedQuotaSamplingIncludesSparseLateClustersAndDetectsMixedOutlier() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        var specs: [(String, String, Double, Double)] = []
        for i in 0..<98 {
            specs.append(("early_\(i)", "sp1", Double(i * 10), Double(i * 10 + 5)))
        }
        specs.append(("late_mid", "sp1", 3000, 3005))
        specs.append(("late_end", "sp1", 6000, 6005))
        try env.writeDocument(speakers: [sp1], turns: specs)

        let resultDir = env.recordingDir.appendingPathComponent("raw/transcripts/\(env.resultID)")
        let doc = try TranscriptDocument.load(from: resultDir.appendingPathComponent("result.json"), recordingDirectory: env.recordingDir)
        let quality = try VoiceAudioQuality.load(in: resultDir, for: doc)
        let edits = try env.writer.loadEdits(resultID: env.resultID)
        let plan = try VoiceAutomaticAssignment.plan(document: doc, edits: edits, quality: quality, hasProfiles: true)
        let plannedIDs = Set(plan.queries.map(\.turn.id))
        #expect(plan.queries.count == 64)
        #expect(plannedIDs.contains("late_mid"))
        #expect(plannedIDs.contains("late_end"))

        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.map { win in
                let isLateMid = (3000 * 16_000 ..< 3010 * 16_000).contains(win.startFrame)
                return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64),
                             embedding: isLateMid ? vecB : vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let updated = try env.writer.loadEdits(resultID: env.resultID)
        #expect(updated.overrides["early_0"]?.displayName == nil)
        #expect(updated.overrides["early_0"]?.voiceRefusal == .ambiguous)
        #expect(updated.overrides["late_mid"]?.voiceRefusal == .ambiguous)
        #expect(updated.overrides["late_end"]?.voiceRefusal == .ambiguous)
    }

    @Test func singleProfileStillRefusesFailedDiarizationSourceWithMissingEvidence() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        try env.coordinator.resetPerson(env.personB.id, delete: false)
        try env.coordinator.resetPerson(env.personC.id, delete: false)

        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        let sp2 = TranscriptDocument.Speaker(id: "sp2", sourceID: .remote, localID: 1, displayNumber: 2)
        try env.writeDocument(
            speakers: [sp1, sp2],
            turns: [("h1", "sp1", 0, 6), ("h_short", "sp1", 7, 8), ("r1", "sp2", 0, 6)],
            includeQuality: false,
            hostDiarization: (.failed, nil),
            remoteDiarization: (.completed, 1)
        )

        let calls = Mutex(0)
        let worker = MockAutoAssignWorker { req in
            calls.withLock { $0 += 1 }
            return .init(requestID: req.id, features: req.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        #expect(calls.withLock { $0 } == 0)
        let edits = try env.writer.loadEdits(resultID: env.resultID)
        #expect(edits.overrides["h1"]?.displayName == nil)
        #expect(edits.overrides["h1"]?.voiceRefusal == .missingEvidence)
        #expect(edits.overrides["h_short"]?.displayName == nil)
        #expect(edits.overrides["h_short"]?.voiceRefusal == .missingEvidence)
        #expect(edits.overrides["r1"]?.displayName == nil)
        #expect(edits.overrides["r1"]?.voiceRefusal == .insufficientProfiles)
    }

    @Test(arguments: [1, 3])
    func groupQuotaPrioritizesDenseSpeechAndMeasuresSparseVoicesWithinBudget(denseCount: Int) async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .host, localID: 1, displayNumber: 1)
        let sources: [TranscriptDocument.Source] = [
            .init(id: .host, originalAudioPath: "raw/host.wav", recognitionAudioPath: "raw/host.wav",
                  diarizationStatus: .completed, detectedVoiceCount: 1, correctionStatus: .disabled),
            .init(id: .remote, originalAudioPath: "raw/remote.wav", recognitionAudioPath: "raw/remote.wav",
                  diarizationStatus: .completed, detectedVoiceCount: 1, correctionStatus: .disabled)
        ]

        var words: [TranscriptDocument.Word] = []
        var turns: [TranscriptDocument.Turn] = []
        // Three lower-density utterances with their clean intervals confirmed by the quality report.
        for (idx, wordText) in ["Да, сейчас вижу", "Доброе утро всем", "Можем обсудить позже"].enumerated() {
            let start = Double(idx * 10)
            let wid = "w_sp_\(idx)"
            words.append(.init(id: wid, speakerID: "sp1", start: start, end: start + 6.0, text: wordText))
            turns.append(.init(id: "t_sparse_\(idx)", speakerID: "sp1", start: start, end: start + 6.0, wordIDs: [wid]))
        }
        for idx in 0..<denseCount {
            let start = Double(30 + idx * 10)
            var wids: [String] = []
            for w in 0..<8 {
                let wid = "w_dn_\(idx)_\(w)"
                let wStart = start + Double(w) * 0.75
                words.append(.init(id: wid, speakerID: "sp1", start: wStart, end: wStart + 0.7, text: "слово"))
                wids.append(wid)
            }
            turns.append(.init(id: "t_dense_\(idx)", speakerID: "sp1", start: start, end: start + 6.0, wordIDs: wids))
        }

        let doc = try TranscriptDocument(
            schemaVersion: 1, resultID: env.resultID, createdAt: "2026-11-21T12:00:00Z",
            sources: sources, speakers: [sp1], words: words, turns: turns, baselineWords: words,
            aec: .init(requested: false, outcome: .disabled),
            playback: .init(status: .unavailable, mixPath: nil),
            warnings: [.init(code: "test", message: "synthetic")])
        let resultDir = env.recordingDir.appendingPathComponent("raw/transcripts/\(env.resultID)")
        try JSONEncoder().encode(doc).write(to: resultDir.appendingPathComponent("result.json"))
        let quality = VoiceAudioQuality(
            resultID: env.resultID, producer: "test",
            sources: [
                .init(id: .host, recognitionAudioPath: "raw/host.wav", fingerprint: String(repeating: "a", count: 64),
                      duration: 100, speech: [.init(start: 0, end: 100)], overlap: []),
                .init(id: .remote, recognitionAudioPath: "raw/remote.wav", fingerprint: String(repeating: "b", count: 64),
                      duration: 100, speech: [.init(start: 0, end: 100)], overlap: [])
            ],
            recordingFingerprint: String(repeating: "c", count: 64))
        try quality.encoded(for: doc).write(to: resultDir.appendingPathComponent(VoiceAudioQuality.filename))

        let limited = try VoiceAutomaticAssignment.plan(document: doc, edits: env.writer.loadEdits(resultID: env.resultID),
                                                        quality: quality, hasProfiles: true, windowBudget: denseCount)
        #expect(limited.queries.map(\.turn.id) == (0..<denseCount).map { "t_dense_\($0)" })
        let sparseStartFrames = Mutex<[Int]>([])
        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.map { win in
                let isSparse = win.startFrame < 30 * 16_000
                if isSparse { sparseStartFrames.withLock { $0.append(win.startFrame) } }
                return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64),
                             embedding: isSparse ? vecB : vecA)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let policy = try #require(VoiceMatchPolicy(threshold: 0.6, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        #expect(sparseStartFrames.withLock { $0 }.count == 3)
        let edits = try env.writer.loadEdits(resultID: env.resultID)
        for turn in turns {
            #expect(edits.overrides[turn.id]?.displayName == nil)
            #expect(edits.overrides[turn.id]?.voiceRefusal == .ambiguous)
        }
    }

    @Test func policyRejectsPermissiveMixedClusterRescue() throws {
        let weakThresh = try #require(VoiceMixedClusterRescuePolicy(threshold: 0.60, margin: 0.20))
        #expect(VoiceMatchPolicy(
            threshold: 0.65, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0,
            mixedClusterRescue: weakThresh
        ) == nil)
        let weakMargin = try #require(VoiceMixedClusterRescuePolicy(threshold: 0.65, margin: 0.15))
        #expect(VoiceMatchPolicy(
            threshold: 0.60, margin: 0.20, calendarBonus: 0, maximumAcousticGap: 0,
            mixedClusterRescue: weakMargin
        ) == nil)
        let valid = VoiceMatchPolicy(
            threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0,
            mixedClusterRescue: VoiceMixedClusterRescuePolicy(threshold: 0.65, margin: 0.20)
        )
        #expect(valid != nil)
    }

    @Test func mixedClusterStrictRescueRescuesPassingMeasuredTurnsAndKeepsOthersAmbiguous() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .remote, localID: 1, displayNumber: 2)
        try env.writeDocument(speakers: [sp1], turns: [
            ("t_passA", "sp1", 0, 4),
            ("t_passB", "sp1", 10, 14),
            ("t_weak", "sp1", 20, 24),
            ("t_lowMargin", "sp1", 30, 34),
            ("t_short", "sp1", 40, 41.5),
            ("t_manual", "sp1", 50, 54)
        ])
        _ = try env.writer.saveTurnOverride(resultID: env.resultID, turnID: "t_manual", text: nil, displayName: "Своё имя")
        env.writer.releaseWriteLock()

        let passAVec: [Float] = [0.90, 0, 0, Float((1.0 - 0.81).squareRoot())] + Array(repeating: 0, count: 252)
        let passBVec: [Float] = [0, 0.88, 0, Float((1.0 - 0.88 * 0.88).squareRoot())] + Array(repeating: 0, count: 252)
        let weakVec: [Float] = [0.62, 0, 0, Float((1.0 - 0.62 * 0.62).squareRoot())] + Array(repeating: 0, count: 252)
        let lowMarginVec: [Float] = [0.70, 0.55, 0, Float((1.0 - 0.49 - 0.3025).squareRoot())] + Array(repeating: 0, count: 252)

        let worker = MockAutoAssignWorker { req in
            .init(requestID: req.id, features: req.windows.map { win in
                let startSec = Double(win.startFrame) / 16_000.0
                let emb: [Float] = switch startSec {
                case 0..<5: passAVec
                case 10..<15: passBVec
                case 20..<25: weakVec
                default: lowMarginVec
                }
                return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: emb)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let rescue = try #require(VoiceMixedClusterRescuePolicy(threshold: 0.65, margin: 0.20))
        let policy = try #require(VoiceMatchPolicy(
            threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0, mixedClusterRescue: rescue
        ))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        #expect(edits.overrides["t_passA"]?.displayName == env.personA.displayName)
        #expect(edits.overrides["t_passA"]?.assignment?.origin == "automaticVoiceMatch")
        #expect(edits.overrides["t_passB"]?.displayName == env.personB.displayName)
        #expect(edits.overrides["t_passB"]?.assignment?.origin == "automaticVoiceMatch")
        for id in ["t_weak", "t_lowMargin", "t_short"] {
            #expect(edits.overrides[id]?.displayName == nil)
            #expect(edits.overrides[id]?.voiceRefusal == .ambiguous)
        }
        #expect(edits.overrides["t_manual"]?.displayName == "Своё имя")
        #expect(edits.overrides["t_manual"]?.assignment?.origin == "manual")
    }

    @Test func mixedClusterStrictRescueEnforcesSubwindowConsensusAndPureAcoustics() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        _ = try env.catalogue.update(env.catalogue.load()) { value in
            value.people[0].calendarBindings = ["anna@example.invalid"]
        }
        let contactURL = try #require(URL(string: "mailto:anna@example.invalid"))
        let participant = try #require(TranscriptDocument.CalendarParticipant(displayName: "Анна", contactURL: contactURL))
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .remote, localID: 1, displayNumber: 2)
        try env.writeDocument(speakers: [sp1], turns: [
            ("t_long_ok", "sp1", 0, 11),
            ("t_long_conflict", "sp1", 20, 31),
            ("t_long_nil", "sp1", 40, 51),
            ("t_cal_override", "sp1", 60, 65),
            ("t_triggerB", "sp1", 70, 75)
        ], calendarParticipants: [participant])

        // Acoustically B=0.70 > A=0.65 (gap 0.05 < 0.20), even though A+0.25 bonus beats B on base policy.
        let calConflictVec: [Float] = [0.65, 0.70, 0.295804] + Array(repeating: 0, count: 253)
        let batchSizes = Mutex<[Int]>([])
        let worker = MockAutoAssignWorker { req in
            batchSizes.withLock { $0.append(req.windows.count) }
            return .init(requestID: req.id, features: req.windows.map { win in
                let midSec = (Double(win.startFrame) + Double(win.endFrame)) * 0.5 / 16_000.0
                let emb: [Float]? = switch midSec {
                case 0..<12: vecA
                case 20..<25.5: vecA
                case 25.5..<32: vecB
                case 40..<45.5: vecA
                case 45.5..<52: nil
                case 60..<66: calConflictVec
                default: vecB
                }
                return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: emb)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let rescue = try #require(VoiceMixedClusterRescuePolicy(threshold: 0.65, margin: 0.20))
        let policy = try #require(VoiceMatchPolicy(
            threshold: 0.60, margin: 0.15, calendarBonus: 0.25, maximumAcousticGap: 0.10, mixedClusterRescue: rescue
        ))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        #expect(batchSizes.withLock { $0.count } == 2)
        let edits = try env.writer.loadEdits(resultID: env.resultID)
        #expect(edits.overrides["t_long_ok"]?.assignment?.personID == env.personA.id)
        #expect(edits.overrides["t_triggerB"]?.assignment?.personID == env.personB.id)
        for id in ["t_long_conflict", "t_long_nil", "t_cal_override"] {
            #expect(edits.overrides[id]?.displayName == nil)
            #expect(edits.overrides[id]?.voiceRefusal == .ambiguous)
        }

        // Single-leader group with long turn does not run a second rescue pass.
        let singleEnv = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { singleEnv.cleanup() }
        try singleEnv.writeDocument(speakers: [sp1], turns: [("t_clean_long", "sp1", 0, 11)])
        let cleanBatches = Mutex(0)
        let cleanWorker = MockAutoAssignWorker { req in
            cleanBatches.withLock { $0 += 1 }
            return .init(requestID: req.id, features: req.windows.map {
                .init(windowID: $0.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: vecA)
            })
        }
        let cleanProcessing = ProcessingService(transcriptionRunner: cleanWorker, audioExporter: cleanWorker, voiceRunner: cleanWorker)
        try await singleEnv.coordinator.automaticallyAssign(
            recordingURL: singleEnv.recordingURL, resultID: singleEnv.resultID, processing: cleanProcessing, policy: policy)
        #expect(cleanBatches.withLock { $0 } == 1)
    }

    @Test func mixedClusterStrictRescueIncludesPrimaryWindowConflictAndNil() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .remote, localID: 1, displayNumber: 2)
        try env.writeDocument(speakers: [sp1], turns: [
            ("t_primary_conflict", "sp1", 0, 11),
            ("t_primary_nil", "sp1", 20, 31),
            ("t_okA", "sp1", 40, 45),
            ("t_okB", "sp1", 50, 55)
        ])

        // Centered pass-1 window for [0, 11] is (40_000, 136_000); for [20, 31] is (360_000, 456_000).
        let requestedRanges = Mutex<[(Int, Int)]>([])
        let worker = MockAutoAssignWorker { req in
            requestedRanges.withLock { $0.append(contentsOf: req.windows.map { ($0.startFrame, $0.endFrame) }) }
            return .init(requestID: req.id, features: req.windows.map { win in
                let emb: [Float]? = switch win.startFrame {
                case 40_000: vecB        // t_primary_conflict pass-1 primary conflicts (B vs subwindows A)
                case 0..<176_000: vecA   // pass-2 subwindows of t_primary_conflict (if queried) would be A
                case 360_000: nil        // t_primary_nil pass-1 primary is nil
                case 320_000..<496_000: vecA
                case 640_000..<800_000: vecA
                default: vecB
                }
                return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64), embedding: emb)
            })
        }
        let processing = ProcessingService(transcriptionRunner: worker, audioExporter: worker, voiceRunner: worker)
        let rescue = try #require(VoiceMixedClusterRescuePolicy(threshold: 0.65, margin: 0.20))
        let policy = try #require(VoiceMatchPolicy(
            threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0, mixedClusterRescue: rescue
        ))
        try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, processing: processing, policy: policy)

        let edits = try env.writer.loadEdits(resultID: env.resultID)
        #expect(edits.overrides["t_okA"]?.assignment?.personID == env.personA.id)
        #expect(edits.overrides["t_okB"]?.assignment?.personID == env.personB.id)
        for id in ["t_primary_conflict", "t_primary_nil"] {
            #expect(edits.overrides[id]?.displayName == nil)
            #expect(edits.overrides[id]?.voiceRefusal == .ambiguous)
        }
        // Primary window (40_000, 136_000) is queried once in pass 1 (not re-extracted in pass 2);
        // t_primary_nil's extra subwindows are skipped since pass 1 already returned nil.
        let ranges = requestedRanges.withLock { $0 }
        #expect(ranges.count == 6)
        #expect(ranges.filter { $0 == (40_000, 136_000) }.count == 1)
        #expect(!ranges.contains { $0.0 == 322_400 || $0.0 == 408_000 })

        // Direct unit check on overrides(): even if a RescuePlan provides passing pass-2 subwindows,
        // primary conflict and primary nil MUST still prevent rescue.
        let resultDir = env.recordingDir.appendingPathComponent("raw/transcripts/\(env.resultID)")
        let doc = try TranscriptDocument.load(from: resultDir.appendingPathComponent("result.json"), recordingDirectory: env.recordingDir)
        let quality = try VoiceAudioQuality.load(in: resultDir, for: doc)
        let emptyEdits = TranscriptEdits(schemaVersion: 2, resultID: env.resultID, revision: 0, overrides: [:])
        let plan = try VoiceAutomaticAssignment.plan(document: doc, edits: emptyEdits, quality: quality, hasProfiles: true)
        let queriesByTurn = Dictionary(uniqueKeysWithValues: plan.queries.map { ($0.turn.id, $0) })
        let conflictQ = try #require(queriesByTurn["t_primary_conflict"])
        let nilQ = try #require(queriesByTurn["t_primary_nil"])
        let okAQ = try #require(queriesByTurn["t_okA"])
        let okBQ = try #require(queriesByTurn["t_okB"])
        let subC1 = VoiceEmbeddingProtocol.Window(
            sourceID: .remote, sourceFingerprint: conflictQ.window.sourceFingerprint, startFrame: 2_400, endFrame: 88_000)
        let subC2 = VoiceEmbeddingProtocol.Window(
            sourceID: .remote, sourceFingerprint: conflictQ.window.sourceFingerprint, startFrame: 88_000, endFrame: 173_600)
        let subN1 = VoiceEmbeddingProtocol.Window(
            sourceID: .remote, sourceFingerprint: nilQ.window.sourceFingerprint, startFrame: 322_400, endFrame: 408_000)
        let subN2 = VoiceEmbeddingProtocol.Window(
            sourceID: .remote, sourceFingerprint: nilQ.window.sourceFingerprint, startFrame: 408_000, endFrame: 493_600)
        let syntheticRescue = VoiceAutomaticAssignment.RescuePlan(
            extraWindows: [subC1, subC2, subN1, subN2],
            windowsByTurn: [
                "t_primary_conflict": [subC1, subC2], // deliberately omit primary to prove overrides() still includes it
                "t_primary_nil": [subN1, subN2]
            ]
        )
        let fp = String(repeating: "f", count: 64)
        let directResponses: [UUID: VoiceEmbeddingProtocol.Feature] = [
            conflictQ.window.id: .init(windowID: conflictQ.window.id, pcmFingerprint: fp, embedding: vecB),
            subC1.id: .init(windowID: subC1.id, pcmFingerprint: fp, embedding: vecA),
            subC2.id: .init(windowID: subC2.id, pcmFingerprint: fp, embedding: vecA),
            nilQ.window.id: .init(windowID: nilQ.window.id, pcmFingerprint: fp, embedding: nil),
            subN1.id: .init(windowID: subN1.id, pcmFingerprint: fp, embedding: vecA),
            subN2.id: .init(windowID: subN2.id, pcmFingerprint: fp, embedding: vecA),
            okAQ.window.id: .init(windowID: okAQ.window.id, pcmFingerprint: fp, embedding: vecA),
            okBQ.window.id: .init(windowID: okBQ.window.id, pcmFingerprint: fp, embedding: vecB),
        ]
        let directOverrides = VoiceAutomaticAssignment.overrides(
            for: plan, rescuePlan: syntheticRescue, responses: directResponses,
            catalogue: try env.catalogue.load().catalogue, edits: emptyEdits, contacts: [], policy: policy
        )
        #expect(directOverrides["t_primary_conflict"]?.displayName == nil)
        #expect(directOverrides["t_primary_conflict"]?.voiceRefusal == .ambiguous)
        #expect(directOverrides["t_primary_nil"]?.displayName == nil)
        #expect(directOverrides["t_primary_nil"]?.voiceRefusal == .ambiguous)
    }

    @Test func mixedClusterStrictRescueReusesAnotherTurnsPrimaryWindow() async throws {
        let env = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { env.cleanup() }
        let speaker = TranscriptDocument.Speaker(id: "sp1", sourceID: .remote, localID: 1, displayNumber: 2)
        try env.writeDocument(speakers: [speaker], turns: [
            ("long", "sp1", 0.85, 25.15),
            ("short", "sp1", 18.85, 25.15)
        ])
        let rescue = try #require(VoiceMixedClusterRescuePolicy(threshold: 0.65, margin: 0.20))
        let policy = try #require(VoiceMatchPolicy(
            threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0, mixedClusterRescue: rescue
        ))
        let batches = Mutex<[[VoiceEmbeddingProtocol.Window]]>([])
        _ = try await env.coordinator.automaticallyAssign(
            recordingURL: env.recordingURL, resultID: env.resultID, policy: policy
        ) { request in
            let isPrimary = batches.withLock { values in
                values.append(request.windows)
                return values.count == 1
            }
            return .init(requestID: request.id, features: request.windows.map { window in
                .init(windowID: window.id, pcmFingerprint: String(repeating: "f", count: 64),
                      embedding: isPrimary && window.startFrame == 304_000 ? vecB : vecA)
            })
        }
        let requests = batches.withLock { $0 }
        #expect(requests.map(\.count) == [2, 2])
        let sharedRequests = requests.flatMap { $0 }.filter { $0.startFrame == 304_000 && $0.endFrame == 400_000 }
        #expect(sharedRequests.count == 1)
        let edits = try env.writer.loadEdits(resultID: env.resultID)
        #expect(edits.overrides["long"]?.voiceRefusal == .ambiguous)
        #expect(edits.overrides["short"]?.assignment?.personID == env.personB.id)
    }

    @Test(arguments: [false, true])
    func mixedClusterStrictRescueSplitsExtraWindowsInto64WindowBatchesAndHonorsCancellationBetweenBatches(cancelTask: Bool) async throws {
        let rescue = try #require(VoiceMixedClusterRescuePolicy(threshold: 0.65, margin: 0.20))
        let policy = try #require(VoiceMatchPolicy(
            threshold: 0.60, margin: 0.15, calendarBonus: 0, maximumAcousticGap: 0, mixedClusterRescue: rescue
        ))
        let sp1 = TranscriptDocument.Speaker(id: "sp1", sourceID: .remote, localID: 1, displayNumber: 2)
        // 40 long 11s turns -> 40 pass-1 windows + 80 pass-2 extra subwindows ([64, 16]).
        let specs: [(String, String, Double, Double)] = (0..<40).map { i in
            ("t_\(i)", "sp1", Double(i * 20), Double(i * 20 + 11))
        }

        // Subtest A: normal multi-batch rescue execution ([40, 64, 16]).
        let envA = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { envA.cleanup() }
        try envA.writeDocument(speakers: [sp1], turns: specs)
        let batchesA = Mutex<[Int]>([])
        let workerA = MockAutoAssignWorker { req in
            batchesA.withLock { $0.append(req.windows.count) }
            return .init(requestID: req.id, features: req.windows.map { win in
                let isLastTurn = win.startFrame >= 39 * 20 * 16_000
                return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64),
                             embedding: isLastTurn ? vecB : vecA)
            })
        }
        let outcomeA = try await envA.coordinator.automaticallyAssign(
            recordingURL: envA.recordingURL, resultID: envA.resultID, policy: policy
        ) { req in
            try await workerA.extractVoiceEmbeddings(req, recordingDirectory: envA.recordingDir)
        }
        #expect(outcomeA == .applied)
        #expect(batchesA.withLock { $0 } == [40, 64, 16])
        let editsA = try envA.writer.loadEdits(resultID: envA.resultID)
        for i in 0..<39 {
            #expect(editsA.overrides["t_\(i)"]?.assignment?.personID == envA.personA.id)
        }
        #expect(editsA.overrides["t_39"]?.assignment?.personID == envA.personB.id)

        // Exercise both cancellation and the generation fence before the last batch.
        let envB = try Env(vecA: vecA, vecB: vecB, vecC: vecC)
        defer { envB.cleanup() }
        try envB.writeDocument(speakers: [sp1], turns: specs)
        let batchesB = Mutex<[Int]>([])
        let interrupted = await Task {
            try await envB.coordinator.automaticallyAssign(
                recordingURL: envB.recordingURL, resultID: envB.resultID, policy: policy
            ) { req in
                let countSoFar = batchesB.withLock { list -> Int in
                    list.append(req.windows.count)
                    return list.count
                }
                if countSoFar == 2 {
                    if cancelTask {
                        withUnsafeCurrentTask { $0?.cancel() }
                    } else {
                        envB.coordinator.setEnabled(false)
                    }
                }
                return .init(requestID: req.id, features: req.windows.map { win in
                    let isLastTurn = win.startFrame >= 39 * 20 * 16_000
                    return .init(windowID: win.id, pcmFingerprint: String(repeating: "f", count: 64),
                                 embedding: isLastTurn ? vecB : vecA)
                })
            }
        }.result
        if cancelTask {
            #expect(throws: CancellationError.self) { try interrupted.get() }
        } else {
            #expect(try interrupted.get() == .skippedFeatureDisabled)
        }
        #expect(batchesB.withLock { $0 } == [40, 64])
        let editsB = try envB.writer.loadEdits(resultID: envB.resultID)
        #expect(editsB.overrides.isEmpty)
    }
}

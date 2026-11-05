import Testing
import Foundation
import MeetingCompanionCore
import MeetingCompanionApplication
import CryptoKit
@testable import MeetingTranscriptionPipeline

@Suite("TranscriptPublisher Tests")
struct TranscriptPublisherTests {

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("publisher-test-\(UUID().uuidString)").appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makeValidDocument(resultID: String = "res_test123", readyPlayback: Bool = true) throws -> TranscriptDocument {
        let source = TranscriptDocument.Source(
            id: .host,
            originalAudioPath: "raw/host.wav",
            recognitionAudioPath: "raw/host.wav",
            diarizationStatus: .completed,
            detectedVoiceCount: 1,
            correctionStatus: .completed
        )
        let speaker = TranscriptDocument.Speaker(
            id: "spk_h1",
            sourceID: .host,
            localID: 1,
            displayNumber: 1
        )
        let word = TranscriptDocument.Word(
            id: "w_h_1",
            speakerID: "spk_h1",
            start: 0.0,
            end: 0.5,
            text: "Тест"
        )
        let turn = TranscriptDocument.Turn(
            id: "turn_1",
            speakerID: "spk_h1",
            start: 0.0,
            end: 0.5,
            wordIDs: ["w_h_1"]
        )
        let aec = TranscriptDocument.AEC(requested: false, outcome: .disabled)
        let playback = readyPlayback ?
            TranscriptDocument.Playback(status: .ready, mixPath: "raw/transcripts/\(resultID)/mix.m4a") :
            TranscriptDocument.Playback(status: .unavailable, mixPath: nil)

        return try TranscriptDocument(
            schemaVersion: 1,
            resultID: resultID,
            createdAt: "2026-11-02T12:00:00Z",
            sources: [source],
            speakers: [speaker],
            words: [word],
            turns: [turn],
            baselineWords: [word],
            aec: aec,
            playback: playback,
            warnings: []
        )
    }

    @Test func testAtomicPublishSuccess() throws {
        let root = try temporaryDirectory()
        let publisher = TranscriptPublisher(recordingDirectory: root)
        let doc = try makeValidDocument(resultID: "res_abc123")
        let dummyMix = "dummy audio".data(using: .utf8)!

        let publishedURL = try publisher.publish(document: doc, audioMixData: dummyMix)

        #expect(FileManager.default.fileExists(atPath: publishedURL.path))
        #expect(publishedURL.lastPathComponent == "result.json")

        // Check that staging directories were properly cleaned up
        let transcriptsDir = root.appendingPathComponent("raw/transcripts")
        let contents = try FileManager.default.contentsOfDirectory(atPath: transcriptsDir.path)
        #expect(contents.contains("res_abc123"))
        #expect(!contents.contains { $0.hasPrefix(".staging-") })

        // Validate that JSONDecoder can parse and validate it as TranscriptDocument
        let data = try Data(contentsOf: publishedURL)
        let loaded = try JSONDecoder().decode(TranscriptDocument.self, from: data)
        #expect(loaded.resultID == "res_abc123")
        #expect(loaded.words.count == 1)
        #expect(loaded.words[0].text == "Тест")
    }

    @Test func testCompanionFilePublish() throws {
        let root = try temporaryDirectory()
        let publisher = TranscriptPublisher(recordingDirectory: root)
        let doc = try makeValidDocument(resultID: "res_comp123")

        let mixData = "dummy audio content".data(using: .utf8)!
        let journalData = "{}".data(using: .utf8)!

        _ = try publisher.publish(
            document: doc,
            audioMixData: mixData,
            correctionJournalData: journalData
        )

        let targetAudio = root.appendingPathComponent("raw/transcripts/res_comp123/mix.m4a")
        let targetJournal = root.appendingPathComponent("raw/transcripts/res_comp123/correction_journal.json")
        #expect(FileManager.default.fileExists(atPath: targetAudio.path))
        #expect(FileManager.default.fileExists(atPath: targetJournal.path))
    }

    @Test func testDuplicateResultIDThrows() throws {
        let root = try temporaryDirectory()
        let publisher = TranscriptPublisher(recordingDirectory: root)
        let doc = try makeValidDocument(resultID: "res_dup123")
        let dummyMix = "dummy audio".data(using: .utf8)!

        _ = try publisher.publish(document: doc, audioMixData: dummyMix)

        // Attempting to publish again with the same resultID must throw destinationExists
        #expect(throws: TranscriptPublishError.self) {
            try publisher.publish(document: doc, audioMixData: dummyMix)
        }
    }

    @Test func testPathEscapeRejected() throws {
        let root = try temporaryDirectory()
        _ = TranscriptPublisher(recordingDirectory: root)

        // ResultID with path traversal is rejected at document creation
        #expect(throws: TranscriptDocument.LoadError.self) {
            _ = try makeValidDocument(resultID: "../escape")
        }
    }
    @Test func rootExportFailureMustRetainCommittedCurrentText() throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rootText = root.appendingPathComponent("meeting.sources.transcript.txt")
        try FileManager.default.createDirectory(at: rootText, withIntermediateDirectories: true)
        let doc = try makeValidDocument(resultID: "committed")
        do {
            let result = try TranscriptPublisher(recordingDirectory: root).publish(document: doc, audioMixData: Data([0]), recordingStem: "meeting")
            #expect(FileManager.default.fileExists(atPath: result.path))
            #expect(try String(contentsOf: result.deletingLastPathComponent().appendingPathComponent("transcript.txt"), encoding: .utf8).contains("Тест"))
        } catch { Issue.record("Post-commit root export must warn, not throw publication failure: \(error)") }
    }

    @Test(arguments: ["mandatoryFile", "cancel"])
    func beforeCommitFailurePreservesPriorAndSources(kind: String) throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let publisher = TranscriptPublisher(recordingDirectory: root)
        let prior = try publisher.publish(document: makeValidDocument(resultID: "A"), audioMixData: Data([1]), recordingStem: "meeting")
        let before = try Data(contentsOf: prior)
        let rootText = try Data(contentsOf: root.appendingPathComponent("meeting.sources.transcript.txt"))
        let originals = ["host", "remote"].map { root.appendingPathComponent("raw/meeting." + $0 + "_record.wav") }
        for source in originals { try Data([1, 2, 3]).write(to: source) }
        let hashes = try originals.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        var checks = 0
        #expect(throws: Error.self) {
            try publisher.publish(document: makeValidDocument(resultID: "B"), audioMixData: Data([2]), recordingStem: "meeting",
                checkCancel: { checks += 1; if kind == "cancel", checks == 2 { throw CancellationError() } },
                beforeCommit: { _ in if kind == "mandatoryFile" { throw CocoaError(.fileWriteOutOfSpace) } })
        }
        #expect(try TranscriptResultStorage(recordingDirectory: root).currentDocument()?.resultID == "A")
        #expect(try Data(contentsOf: prior) == before)
        #expect(try Data(contentsOf: root.appendingPathComponent("meeting.sources.transcript.txt")) == rootText)
        #expect(try originals.map { SHA256.hash(data: try Data(contentsOf: $0)) } == hashes)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("raw/transcripts").path) == ["A"])
    }

    @Test(arguments: ["success", "ack", "cancel", "status", "rootExport"])
    func committedPublicationSurvivesRunnerAndStatusFailures(kind: String) async throws {
        let root = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let recording = root.appendingPathComponent("meeting.m4a")
        let publisher = TranscriptPublisher(recordingDirectory: root)
        _ = try publisher.publish(document: makeValidDocument(resultID: "A"), audioMixData: Data([1]), recordingStem: "meeting")
        try FileManager.default.setAttributes([.creationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: root.appendingPathComponent("raw/transcripts/A").path)
        let originals = ["host", "remote"].map { root.appendingPathComponent("raw/meeting." + $0 + "_record.wav") }
        for source in originals { try Data([1, 2, 3]).write(to: source) }
        let hashes = try originals.map { SHA256.hash(data: try Data(contentsOf: $0)) }
        let metadata = root.appendingPathComponent("raw/meeting.processing.json")
        try Data("{\"selectedResultID\":\"A\",\"recordingFormatVersion\":1,\"recordingFormatVersion\":999,\"precise\":123456789012345678901234567890.123456789}".utf8).write(to: metadata)
        if kind == "rootExport" {
            try FileManager.default.removeItem(at: root.appendingPathComponent("meeting.sources.transcript.txt"))
            try FileManager.default.createDirectory(at: root.appendingPathComponent("meeting.sources.transcript.txt"), withIntermediateDirectories: true)
        }
        let repo = RecordingHistoryRepository()
        repo.put(RecordingEntry.load(recording: recording), persist: false)
        let runner = PublicationRunner(document: try makeValidDocument(resultID: "B"), kind: kind, metadata: metadata)
        let service = ProcessingService(transcriptionRunner: runner, audioExporter: PublicationExporter(), historyRepository: repo)
        let (stream, continuation) = AsyncStream<ProcessingService.Event>.makeStream()
        await service.addEventHandler { continuation.yield($0) }
        let job = await service.enqueue(recordingURL: recording, settings: .init(parakeet: false, echoCancellation: false))
        var returned: URL?
        var warning: String?
        for await event in stream {
            switch event {
            case .completed(let finished, let text, let message):
                #expect(finished.id == job.id); returned = text; warning = message; continuation.finish()
            case .failed, .cancelled:
                Issue.record("A committed B must remain completed, including cancellation/ack/status failure"); continuation.finish()
            default: break
            }
        }
        let text = try #require(returned)
        #expect(text.path.hasSuffix("raw/transcripts/B/transcript.txt"))
        #expect(try String(contentsOf: text, encoding: .utf8).contains("Тест"))
        #expect(try TranscriptResultStorage(recordingURL: recording).currentDocument()?.resultID == "B")
        #expect(repo.entry(recording)?.phase == .completed)
        #expect(await service.totalJobCount == 0)
        #expect((warning != nil) == (kind != "success"))
        let state = try await TranscriptWindowCoordinator().openWindow(for: recording).state
        #expect(await state.activeResultID == "B")
        #expect(try originals.map { SHA256.hash(data: try Data(contentsOf: $0)) } == hashes)
        if kind == "status" { #expect(try Data(contentsOf: metadata) == Data("{broken".utf8)) }
    }

}

private struct PublicationExporter: AudioExporterProtocol {
    func exportMixedAudio(from inputs: [URL], to output: URL) async throws {}
}
private struct PublicationRunner: TranscriptionRunnerProtocol {
    let document: TranscriptDocument
    let kind: String
    let metadata: URL
    func checkDependenciesWithOutput(prepare: Bool, availability: Bool, parakeet: Bool,
        onOutput: (@Sendable (String) -> Void)?) async throws -> (output: String, succeeded: Bool) { ("", true) }
    func run(recording: URL, parakeet: Bool, echoCancellation: Bool,
        onProgress: (@Sendable (TranscriptionProgress) -> Void)?) async throws -> URL {
        let result = try TranscriptPublisher(recordingDirectory: recording.deletingLastPathComponent()).publish(
            document: document, audioMixData: Data([2]), recordingStem: "meeting",
            onWarning: { onProgress?(.init(stage: .warning, completed: 0, total: 1, warning: $0)) })
        if kind == "status" { try Data("{broken".utf8).write(to: metadata) }
        if kind == "ack" { throw CocoaError(.fileReadUnknown) }
        if kind == "cancel" { throw CancellationError() }
        return result.deletingLastPathComponent().appendingPathComponent("transcript.txt")
    }
}

import Foundation
import Testing
import MeetingCompanionCore
@testable import MeetingTranscriptionPipeline

@Suite struct TranscriptContinuationPublicationTests {
    @Test func lateDurationBoundaryDoesNotHideEarlierUnambiguousPair() throws {
        func channel(_ id: TranscriptDocument.SourceID, _ words: [PipelineWord]) -> PipelineRunner.ChannelAudio {
            let path = "raw/meeting.\(id.rawValue)_record.wav"
            return .init(id: id, originalURL: URL(fileURLWithPath: "/unused/" + path),
                recognitionURL: URL(fileURLWithPath: "/unused/" + path),
                originalRelPath: path, recognitionRelPath: path, sha256: "unused", frameCount: 0, duration: 0,
                gigaamWords: words, finalWords: words, correctionStatus: .disabled)
        }
        let host = (0...31).map { PipelineWord(start: Double($0), end: Double($0) + 0.8, text: "слово\($0)", speaker: 1) }
        let remote = [PipelineWord(start: 0.5, end: 0.7, text: "вставка1", speaker: 1),
                      PipelineWord(start: 1.5, end: 1.7, text: "вставка2", speaker: 2)]
        let doc = try PipelineRunner.assembleDocument(channels: [channel(.host, host), channel(.remote, remote)],
            resultID: "res_long", aec: .init(requested: false, outcome: .disabled),
            playback: .init(status: .unavailable, mixPath: nil),
            additionalWarnings: [.init(code: "playback_mix_failed", sourceID: nil, message: "Synthetic text-only")])
        let text = try TranscriptExportFormatter().format(document: doc, edits: .initial(resultID: doc.resultID))
        #expect(text.contains("слово0…"))
        #expect(text.contains("…слово1"))
        #expect(doc.turns.last?.wordIDs.count == 30)
    }

    @Test func generatedAndUserExportsShareMarkersAndPreserveJSON() throws {
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/chronological.json")
        let doc = try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: fixture))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString).appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let published = try TranscriptPublisher(recordingDirectory: root).publish(document: doc, recordingStem: "meeting")
        let generated = try String(contentsOf: published.deletingLastPathComponent().appendingPathComponent("transcript.txt"), encoding: .utf8)
        let exported = try TranscriptExportFormatter().format(document: doc, edits: .initial(resultID: doc.resultID))
        for text in ["Обсудим…", "Да", "…релиз"] {
            #expect(generated.contains(text))
            #expect(exported.contains(text))
        }
        let loaded = try TranscriptDocument.load(from: published, recordingDirectory: root)
        #expect(loaded.words == doc.words && loaded.baselineWords == doc.baselineWords && loaded.turns == doc.turns)
    }
}

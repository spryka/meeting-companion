import Foundation
import Testing
import MeetingCompanionCore
@testable import MeetingTranscriptionPipeline

@Suite("Pipeline document assembly")
struct PipelineDocumentAssemblyTests {
    private func encoded(_ document: TranscriptDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(document)
    }

    private func channel(
        _ id: TranscriptDocument.SourceID,
        final: [PipelineWord], baseline: [PipelineWord],
        status: TranscriptDocument.ProcessingStatus = .completed
    ) -> PipelineRunner.ChannelAudio {
        let path = "raw/meeting.\(id.rawValue)_record.wav"
        let unusedURL = URL(fileURLWithPath: "/unused/" + path)
        return PipelineRunner.ChannelAudio(
            id: id, originalURL: unusedURL, recognitionURL: unusedURL,
            originalRelPath: path, recognitionRelPath: path,
            sha256: "unused", frameCount: 0, duration: 0,
            gigaamWords: baseline, finalWords: final, correctionStatus: status
        )
    }

    private func assemble(_ channels: [PipelineRunner.ChannelAudio]) throws -> TranscriptDocument {
        try PipelineRunner.assembleDocument(
            channels: channels, resultID: "res_assembly",
            aec: .init(requested: false, outcome: .disabled),
            playback: .init(status: .unavailable, mixPath: nil),
            additionalWarnings: [.init(code: "playback_mix_failed", sourceID: nil, message: "Synthetic text-only publication")]
        )
    }

    @Test func baselineOnlyHostAndRemoteSpeakersRoundtripAndPublish() throws {
        let hostBaseline = [
            PipelineWord(start: 0, end: 1, text: "host baseline", speaker: nil),
            PipelineWord(start: 1, end: 2, text: "host seven", speaker: 7)
        ]
        let remoteBaseline = [
            PipelineWord(start: 0, end: 1, text: "remote baseline", speaker: 1),
            PipelineWord(start: 1, end: 2, text: "remote three", speaker: 3)
        ]
        let document = try assemble([
            channel(.host, final: [.init(start: 0, end: 2, text: "host final", speaker: 1)], baseline: hostBaseline),
            channel(.remote, final: [.init(start: 0, end: 2, text: "remote final", speaker: 1)], baseline: remoteBaseline)
        ])
        #expect(document.speakers.map(\.id) == ["spk_h1", "spk_h7", "spk_r1", "spk_r3"])
        #expect(document.speakers.map(\.displayNumber) == [1, 7, 8, 10])
        #expect(document.baselineWords.map(\.speakerID) == ["spk_h1", "spk_h7", "spk_r1", "spk_r3"])
        #expect(document.baselineWords.map(\.text) == (hostBaseline + remoteBaseline).map(\.text))
        #expect(document.baselineWords.map(\.start) == [0, 1, 0, 1])
        #expect(document.baselineWords.map(\.end) == [1, 2, 1, 2])
        let roundtrip = try JSONDecoder().decode(TranscriptDocument.self, from: JSONEncoder().encode(document))
        #expect(try encoded(roundtrip) == encoded(document))

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = scratch.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let published = try TranscriptPublisher(recordingDirectory: root).publish(document: document, recordingStem: "meeting")
        let loaded = try TranscriptDocument.load(from: published, recordingDirectory: root)
        #expect(try encoded(loaded) == encoded(document))
        let text = try String(contentsOf: published.deletingLastPathComponent().appendingPathComponent("transcript.txt"), encoding: .utf8)
        #expect(text.contains("host final"))
        #expect(text.contains("remote final"))
    }

    @Test func baselineOnlyRemoteSpeakerIsRegisteredIndependently() throws {
        let final = [PipelineWord(start: 0, end: 1, text: "final", speaker: 1)]
        let document = try assemble([
            channel(.host, final: final, baseline: final),
            channel(.remote, final: final, baseline: [.init(start: 0, end: 1, text: "remote baseline", speaker: 3)])
        ])
        #expect(document.speakers.map(\.id) == ["spk_h1", "spk_r1", "spk_r3"])
        #expect(document.speakers.map(\.displayNumber) == [1, 2, 4])
        #expect(document.baselineWords.last?.speakerID == "spk_r3")
    }

    @Test(arguments: [TranscriptDocument.ProcessingStatus.disabled, .failed])
    func unsuccessfulCorrectionPreservesFinalBaselineSignatures(status: TranscriptDocument.ProcessingStatus) throws {
        let final = [PipelineWord(start: 0.25, end: 1.5, text: "unchanged", speaker: nil)]
        let unusedBaseline = [PipelineWord(start: 0, end: 2, text: "not serialized", speaker: 7)]
        let document = try assemble([
            channel(.host, final: final, baseline: unusedBaseline, status: status),
            channel(.remote, final: final, baseline: unusedBaseline, status: status)
        ])
        #expect(document.speakers.map(\.id) == ["spk_h1", "spk_r1"])
        #expect(document.speakers.map(\.displayNumber) == [1, 2])
        #expect(document.words.map(\.text) == document.baselineWords.map(\.text))
        #expect(document.words.map(\.start) == document.baselineWords.map(\.start))
        #expect(document.words.map(\.end) == document.baselineWords.map(\.end))
        #expect(document.words.map(\.speakerID) == document.baselineWords.map(\.speakerID))
        let roundtrip = try JSONDecoder().decode(TranscriptDocument.self, from: encoded(document))
        #expect(try encoded(roundtrip) == encoded(document))
    }

    @Test func unknownBaselineSpeakerStillFailsStrictValidation() throws {
        let word = PipelineWord(start: 0, end: 1, text: "baseline", speaker: 1)
        let document = try assemble([channel(.host, final: [word], baseline: [word])])
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(document)) as? [String: Any])
        var baseline = try #require(json["baselineWords"] as? [[String: Any]])
        baseline[0]["speakerID"] = "missing"
        json["baselineWords"] = baseline
        do {
            _ = try JSONDecoder().decode(TranscriptDocument.self, from: JSONSerialization.data(withJSONObject: json))
            Issue.record("Unknown baseline speaker was accepted")
        } catch TranscriptDocument.LoadError.invalidReference(let detail) {
            #expect(detail == "голос слова bw_h_1")
        }
    }

    @Test(arguments: [0, -1])
    func nonpositiveSourceLocalSpeakerStillFails(speaker: Int) throws {
        let word = PipelineWord(start: 0, end: 1, text: "invalid", speaker: speaker)
        #expect(throws: TranscriptDocument.LoadError.self) {
            try assemble([channel(.host, final: [word], baseline: [word])])
        }
    }
}

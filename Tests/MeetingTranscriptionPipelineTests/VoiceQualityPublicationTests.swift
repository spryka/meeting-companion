import Foundation
import MeetingCompanionCore
@testable import MeetingTranscriptionPipeline
import Testing

@Suite struct VoiceQualityPublicationTests {
    @Test func qualityIntervalsDistinguishSameSpeakerFromOverlap() {
        let intervals = PipelineRunner.voiceIntervals([
            .init(start: 0, end: 4, speaker: 1),
            .init(start: 2, end: 3, speaker: 1),
            .init(start: 3, end: 5, speaker: 2),
            .init(start: 6, end: 9, speaker: 2)
        ], duration: 8)
        #expect(intervals.speech == [.init(start: 0, end: 5), .init(start: 6, end: 8)])
        #expect(intervals.overlap == [.init(start: 3, end: 4)])
    }

    @Test(arguments: [false, true])
    func qualityIsValidatedAndPublishedWithTheResult(invalid: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recording = root.appendingPathComponent("meeting")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_empty_voices.json")
        let document = try JSONDecoder().decode(TranscriptDocument.self, from: Data(contentsOf: fixture))
        let source = try #require(document.sources.first)
        let quality = VoiceAudioQuality(resultID: invalid ? "wrong-result" : document.resultID, producer: "test",
            sources: [.init(id: source.id, recognitionAudioPath: source.recognitionAudioPath,
                            fingerprint: String(repeating: "a", count: 64), duration: 5,
                            speech: [.init(start: 0, end: 3)], overlap: [.init(start: 1, end: 2)])])
        var warnings: [String] = []
        let result = try TranscriptPublisher(recordingDirectory: recording).publish(
            document: document, audioMixData: Data([1]), voiceQuality: quality, beforeCommit: { staging in
                #expect(FileManager.default.fileExists(atPath: staging.appendingPathComponent(VoiceAudioQuality.filename).path) != invalid)
            }, onWarning: { warnings.append($0) })
        #expect(FileManager.default.fileExists(atPath: result.path))
        let loaded = try VoiceAudioQuality.load(in: result.deletingLastPathComponent(), for: document)
        #expect(loaded == (invalid ? nil : quality))
        #expect(warnings.isEmpty != invalid)
    }
}

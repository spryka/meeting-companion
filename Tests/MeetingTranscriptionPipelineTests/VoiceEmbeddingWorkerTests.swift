import AVFoundation
import Foundation
import MeetingCompanionCore
import MeetingTranscriptionPipeline
import Testing

@Suite struct VoiceEmbeddingWorkerTests {
    @Test func cancellationStopsBeforeLookingUpTheSourceOrWeights() throws {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let request = VoiceEmbeddingProtocol.Request(resultID: "res_test", windows: [])
        do {
            _ = try VoiceEmbeddingWorker.extract(request, recordingDirectory: absent, modelRoot: absent, isCancelled: { true })
            Issue.record("Cancelled worker returned a response")
        } catch let error as PipelineError {
            #expect(error.message == "cancelled")
        }
    }

    @Test func sourceMismatchAndCorruptWeightsFailBeforeInference() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let resultID = "res_valid_empty_voices"
        let result = root.appendingPathComponent("raw/transcripts/" + resultID)
        let model = root.appendingPathComponent("models/voice")
        try FileManager.default.createDirectory(at: result, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
        try Data("invalid synthetic model".utf8).write(to: model.appendingPathComponent("model.safetensors"))
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/transcript-document/valid_empty_voices.json")
        try FileManager.default.copyItem(at: fixture, to: result.appendingPathComponent("result.json"))
        let wav = root.appendingPathComponent("raw/meeting.host_record.wav")
        do {
            let file = try AVAudioFile(forWriting: wav, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1, AVLinearPCMBitDepthKey: 16
            ])
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 48_000))
            buffer.frameLength = 48_000
            let data = try #require(buffer.floatChannelData?[0])
            data.initialize(repeating: 0, count: 48_000)
            try file.write(from: buffer)
        }
        let actual = try ModelAssets.computeSHA256(at: wav)
        for (fingerprint, message) in [
            (String(repeating: "0", count: 64), "Изменился источник звука для определения голоса."),
            (actual, "Контрольная сумма модели голосов не совпала.")
        ] {
            let request = VoiceEmbeddingProtocol.Request(resultID: resultID, windows: [
                .init(sourceID: .host, sourceFingerprint: fingerprint, startFrame: 0, endFrame: 48_000)
            ])
            do {
                _ = try VoiceEmbeddingWorker.extract(request, recordingDirectory: root,
                    modelRoot: model.deletingLastPathComponent(), isCancelled: { false })
                Issue.record("Worker accepted invalid input")
            } catch let error as PipelineError {
                #expect(error.message == message)
            }
        }
    }
}

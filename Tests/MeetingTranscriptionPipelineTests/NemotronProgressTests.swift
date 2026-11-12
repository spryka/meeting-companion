import AVFoundation
import Foundation
import Testing
@preconcurrency import MLX
import MeetingCompanionCore
@testable import MeetingTranscriptionPipeline

private final class DiarizationProgressLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [PipelineProgressEvent] = []
    func append(_ event: PipelineProgressEvent) { lock.withLock { values.append(event) } }
    var events: [PipelineProgressEvent] { lock.withLock { values } }
}

@Suite(.serialized) struct NemotronProgressTests {
    @Test(arguments: [false, true])
    func missingIntervalsRemainVisibleBeforeRecognition(damagedModel: Bool) throws {
        let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let metallib = project.appendingPathComponent(".build/out/Products/Debug/mlx-swift_Cmlx.bundle/Contents/Resources/default.metallib")
        try #require(FileManager.default.fileExists(atPath: metallib.path))
        GPU.metallib = metallib
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let recording = root.appendingPathComponent("recording")
        let models = root.appendingPathComponent("models")
        try FileManager.default.createDirectory(at: recording, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        if damagedModel {
            try FileManager.default.createDirectory(at: models.appendingPathComponent("nemotron"), withIntermediateDirectories: true)
        }
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160))
        buffer.frameLength = 160
        for index in 0..<160 { buffer.floatChannelData![0][index] = 0 }
        let host = recording.appendingPathComponent("host.wav")
        let remote = recording.appendingPathComponent("remote.wav")
        for url in [host, remote] {
            let file = try AVAudioFile(forWriting: url, settings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: 16000.0,
                AVNumberOfChannelsKey: 1,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMIsBigEndianKey: false
            ])
            try file.write(from: buffer)
        }
        let sources = RecordingSources(recordingDirectory: recording, stem: "recording",
            hostWAV: host, remoteWAV: remote, hostRelPath: "host.wav", remoteRelPath: "remote.wav")
        let log = DiarizationProgressLog()
        // No ASR weights: stop after observing the real diarization failure/absence path.
        #expect(throws: (any Error).self) {
            _ = try PipelineRunner(modelRoot: models).run(sources: sources, onProgress: { log.append($0) })
        }
        let events = log.events
        let recognition = try #require(events.firstIndex { $0.stage == .gigaam })
        let terminal = events[..<recognition].filter { $0.stage == .diarization && $0.state != .started && $0.state != nil }
        #expect(terminal.map(\.channel) == ["host", "remote"])
        #expect(terminal.allSatisfy { $0.state == (damagedModel ? .failed : .skipped) })
        #expect(terminal.allSatisfy { $0.warning?.contains("Нет интервалов речи Nemotron; распознаются все окна.") == true })
        #expect(!events.contains { $0.stage.rawValue == "vad" })
    }
}

import Testing
import Foundation
import AVFoundation
@testable import MeetingTranscriptionPipeline

@Suite("AudioMixer Tests")
struct AudioMixerTests {

    private func createTestWAV(url: URL, frames: Int) throws {
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000.0,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let format = file.processingFormat
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        if let ptr = buffer.floatChannelData?[0] {
            for i in 0..<frames {
                ptr[i] = sin(Float(i) * 0.05) * 0.2
            }
        }
        try file.write(from: buffer)
    }

    @Test func testInspectWAV() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let wavURL = tempDir.appendingPathComponent("test.wav")
        try createTestWAV(url: wavURL, frames: 16000) // 1 second

        let count = try AudioMixer.inspectWAV(wavURL)
        #expect(count == 16000)
    }

    @Test func testPrepareMixMatchesDuration() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hostURL = tempDir.appendingPathComponent("host.wav")
        let remoteURL = tempDir.appendingPathComponent("remote.wav")
        let mixURL = tempDir.appendingPathComponent("mix.m4a")

        try createTestWAV(url: hostURL, frames: 32000) // 2 seconds
        try createTestWAV(url: remoteURL, frames: 32000)

        try AudioMixer.prepareMix(host: hostURL, remote: remoteURL, destination: mixURL)

        #expect(FileManager.default.fileExists(atPath: mixURL.path))
        let attrs = try FileManager.default.attributesOfItem(atPath: mixURL.path)
        let size = attrs[.size] as? UInt64 ?? 0
        #expect(size > 0)
    }

    @Test func testPrepareMixMismatchedDurationThrows() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hostURL = tempDir.appendingPathComponent("host.wav")
        let remoteURL = tempDir.appendingPathComponent("remote.wav")
        let mixURL = tempDir.appendingPathComponent("mix.m4a")

        try createTestWAV(url: hostURL, frames: 16000)
        try createTestWAV(url: remoteURL, frames: 32000)

        #expect(throws: AudioMixerError.self) {
            try AudioMixer.prepareMix(host: hostURL, remote: remoteURL, destination: mixURL)
        }
    }
}

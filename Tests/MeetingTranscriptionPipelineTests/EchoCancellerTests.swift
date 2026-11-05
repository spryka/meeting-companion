import Testing
import Foundation
import AVFoundation
@testable import MeetingTranscriptionPipeline
import MeetingCompanionCore

@Suite("EchoCanceller Tests")
struct EchoCancellerTests {

    private func createWAV(url: URL, frames: Int, silent: Bool) throws {
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
                ptr[i] = silent ? 0.0 : (sin(Float(i) * 0.05) * 0.2)
            }
        }
        try file.write(from: buffer)
    }

    @Test func testEchoCancellerZeroReferenceSilentBypass() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hostURL = tempDir.appendingPathComponent("host.wav")
        let remoteURL = tempDir.appendingPathComponent("remote_silent.wav")
        let destURL = tempDir.appendingPathComponent("dest.wav")

        try createWAV(url: hostURL, frames: 16000, silent: false)
        try createWAV(url: remoteURL, frames: 16000, silent: true)

        let result = EchoCanceller.process(
            host: hostURL,
            remote: remoteURL,
            destination: destURL,
            requested: true
        )

        // Silent reference must enter zero-reference bypass
        #expect(result.outcome == .applied)
        #expect(result.warnings.isEmpty)
        #expect(result.audioURL == hostURL)
    }

    @Test func testEchoCancellerNonzeroRemoteReachesHelperBoundary() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let hostURL = tempDir.appendingPathComponent("host.wav")
        let remoteURL = tempDir.appendingPathComponent("remote_nonzero.wav")
        let destURL = tempDir.appendingPathComponent("dest.wav")

        try createWAV(url: hostURL, frames: 16000, silent: false)
        try createWAV(url: remoteURL, frames: 16000, silent: false)

        // Case A: No executable provided or found -> MUST NOT silently bypass, must return failed outcome with warning
        let noExeResult = EchoCanceller.process(
            host: hostURL,
            remote: remoteURL,
            destination: destURL,
            requested: true,
            executableURL: URL(fileURLWithPath: "/nonexistent/meeting-aec")
        )
        #expect(noExeResult.outcome == .failed)
        #expect(noExeResult.warnings.contains { $0.code == "aec_fallback" })

        // Case B: Provide dummy executable that produces expected output frames
        let dummyScriptURL = tempDir.appendingPathComponent("mock-aec.sh")
        // The mock script copies raw PCM from host after the 44-byte WAV header and outputs to stdout
        let scriptContent = """
        #!/bin/sh
        # Arguments: $1=host $2=remote $3=hostOffset $4=remoteOffset $5=frames
        HOST="$1"
        OFFSET="$3"
        FRAMES="$5"
        BYTES=$((FRAMES * 2))
        echo "AEC_PROGRESS $FRAMES $FRAMES" >&2
        dd if="$HOST" bs=1 skip="$OFFSET" count="$BYTES" 2>/dev/null
        exit 0
        """
        try scriptContent.write(to: dummyScriptURL, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dummyScriptURL.path)

        let successResult = EchoCanceller.process(
            host: hostURL,
            remote: remoteURL,
            destination: destURL,
            requested: true,
            executableURL: dummyScriptURL
        )

        #expect(successResult.outcome == .applied)
        #expect(successResult.warnings.isEmpty)
        #expect(successResult.audioURL == destURL)
        #expect(FileManager.default.fileExists(atPath: destURL.path))

        let processedFile = try AVAudioFile(forReading: destURL)
        #expect(Int(processedFile.length) == 16000)
    }
}

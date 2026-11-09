import Testing
import Foundation
import AVFoundation
import CoreMedia
@testable import MeetingCompanionPlatform

@Suite("Source audio finalization")
struct SourceAudioFinalizationTests {
    @Test(arguments: [false, true], [false, true])
    func pendingConverterTailsShareOneEnd(archives: Bool, longerMicrophone: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for tail in 0..<9 {
            let name = "tail-\(tail)"
            let files = try SourceAudioFiles(outputURL: directory.appendingPathComponent(name + ".m4a"), archiveAudio: archives)
            files.start()
            let timestamp = CMClockGetTime(CMClockGetHostTimeClock())
            for microphone in [true, false] {
                let frames = 48000 + (microphone == longerMicrophone ? tail : 0)
                let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                buffer.frameLength = buffer.frameCapacity
                for i in 0..<frames { buffer.floatChannelData![0][i] = 0.25 }
                files.append(buffer, timestamp: timestamp, microphone: microphone)
            }
            try files.finish(duration: 0)
            let host = try AVAudioFile(forReading: directory.appendingPathComponent("raw/\(name).host_record.wav"))
            let remote = try AVAudioFile(forReading: directory.appendingPathComponent("raw/\(name).remote_record.wav"))
            #expect(host.length == remote.length, "Unequal finalized tails: \(tail), archives=\(archives)")
            #expect(host.length >= AVAudioFramePosition((Double(48000 + tail) / 3).rounded()), "Captured tail was truncated")
            if archives {
                let lengths = try files.archiveURLs.map { try AVAudioFile(forReading: $0).length }
                #expect(lengths[0] == lengths[1])
                #expect(lengths[0] >= 48000 + tail)
                #expect(abs(Double(lengths[0]) / 48000 - Double(host.length) / 16000) <= 1.0 / 16000)
            }
        }
    }
}

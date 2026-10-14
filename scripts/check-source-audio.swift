import AVFoundation

@main
struct SourceAudioFilesChecks {
    static func main() async throws {
        let checks = Self()
        try checks.testDelaysAndGapsRemainSilenceInEncodedFile()
        try checks.testOverlappingBufferDoesNotShiftTimeline()
        try checks.testSilentSourceStillHasFullDuration()
        try checks.testExistingFileAndInvalidTimestampAreRejected()
        try checks.testRecordingDayUsesLocalDate()
        try checks.testStreamingStereoResample()
        try await checks.testExistingExportIsPreserved()
        try await checks.testRecordingFailureIsPropagated()
        print("8 recording checks passed")
    }
    private func testExistingExportIsPreserved() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("existing.m4a")
        let original = Data("original recording".utf8)
        try original.write(to: output)
        do {
            try await exportAudioToM4A(from: directory.appendingPathComponent("missing.mp4"), to: output)
            preconditionFailure("Existing recording overwritten")
        } catch SourceAudioError.existingFile {}
        let saved = try Data(contentsOf: output)
        precondition(saved == original)
    }

    private func testRecordingFailureIsPropagated() async throws {
        let finished = AsyncSignal()
        await finished.signal(error: RecorderError.exportFailed)
        await finished.signal()
        do {
            try await finished.wait()
            preconditionFailure("Recording failure ignored")
        } catch RecorderError.exportFailed {}
        let success = AsyncSignal()
        let waiter = Task { try await success.wait() }
        await success.signal()
        try await waiter.value
    }
    func testDelaysAndGapsRemainSilenceInEncodedFile() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("host.wav")
        let source = try SourceAudioFile(url: url)
        try source.append(tone(seconds: 0.1), seconds: 0.5)
        try source.append(tone(seconds: 0.1), seconds: 1.0)
        try source.finish(duration: 1.5)
        let data = try read(url)
        precondition(abs(Double(data.frameLength) / 16000 - 1.5) < 0.03)
        precondition(rms(data, start: 0.1, end: 0.4) < 0.005)
        precondition(rms(data, start: 0.52, end: 0.58) > 0.1)
        precondition(rms(data, start: 0.7, end: 0.9) < 0.005)
        precondition(rms(data, start: 1.02, end: 1.08) > 0.1)
    }

    func testOverlappingBufferDoesNotShiftTimeline() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("remote.wav")
        let source = try SourceAudioFile(url: url)
        try source.append(tone(seconds: 0.2), seconds: 0)
        try source.append(tone(seconds: 0.2), seconds: 0.1)
        try source.finish(duration: 0.3)
        let data = try read(url)
        precondition(abs(Double(data.frameLength) / 16000 - 0.3) < 0.03)
    }

    func testSilentSourceStillHasFullDuration() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silent.wav")
        try SourceAudioFile(url: url).finish(duration: 1)
        let data = try read(url)
        precondition(abs(Double(data.frameLength) / 16000 - 1) < 0.03)
        precondition(rms(data, start: 0.1, end: 0.9) < 0.005)
    }

    func testExistingFileAndInvalidTimestampAreRejected() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("existing.wav")
        try Data("keep".utf8).write(to: url)
        do { _ = try SourceAudioFile(url: url); preconditionFailure("Existing recording overwritten") } catch {}
        let existing = try Data(contentsOf: url)
        precondition(existing == Data("keep".utf8))
        let source = try SourceAudioFile(url: directory.appendingPathComponent("new.wav"))
        do { try source.append(tone(seconds: 0.1), seconds: .nan); preconditionFailure("NaN accepted") } catch {}
    }

    func testStreamingStereoResample() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("stereo.wav")
        let source = try SourceAudioFile(url: url)
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 2)!
        for tick in 0..<100 {
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480)!
            buffer.frameLength = 480
            for index in 0..<480 {
                for channel in 0..<2 {
                    buffer.floatChannelData![channel][index] = Float(sin(Double(tick * 480 + index) * 2 * .pi * 440 / 48000) * 0.3)
                }
            }
            try source.append(buffer, seconds: Double(tick) / 100)
        }
        try source.finish(duration: 1)
        let data = try read(url)
        precondition(data.frameLength == 16000)
        precondition(rms(data, start: 0.1, end: 0.9) > 0.15)
        let values = data.floatChannelData![0]
        for index in 160..<14400 {
            precondition(abs(values[index] - values[index - 1]) < 0.08)
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func testRecordingDayUsesLocalDate() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let date = ISO8601DateFormatter().date(from: "2026-10-12T21:01:02Z")!
        let path = try RecordingPaths.makeOutputURL(outputDirectory: directory, date: date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM/dd/'interview_'yyyy-MM-dd_HH-mm-ss'.m4a'"
        precondition(path.path == directory.appendingPathComponent(formatter.string(from: date)).path)
        precondition(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
    }

    private func tone(seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(seconds * 48000))!
        buffer.frameLength = buffer.frameCapacity
        for index in 0..<Int(buffer.frameLength) {
            buffer.floatChannelData![0][index] = Float(sin(Double(index) * 2 * .pi * 440 / 48000) * 0.3)
        }
        return buffer
    }

    private func read(_ url: URL) throws -> AVAudioPCMBuffer {
        let file = try AVAudioFile(forReading: url)
        precondition(file.fileFormat.sampleRate == 16000 && file.fileFormat.channelCount == 1)
        precondition(file.fileFormat.streamDescription.pointee.mBitsPerChannel == 16)
        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)
        return buffer
    }

    private func rms(_ buffer: AVAudioPCMBuffer, start: Double, end: Double) -> Double {
        let values = buffer.floatChannelData![0]
        let range = Int(start * 16000)..<Int(end * 16000)
        return sqrt(range.reduce(0.0) { $0 + Double(values[$1] * values[$1]) } / Double(range.count))
    }
}

import AVFoundation

final class DeliveryCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); defer { lock.unlock() }; value += 1 }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

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
        try await checks.testAudioOnlyMixAndArchives()
        try checks.testMutedBuffersAndArchivesRemainSilent()
        try checks.testSilenceIsWrittenIncrementally()
        try checks.testDeliveryOverflowIsBoundedAndCounted()
        try await checks.testCaptureWarningStillProducesRecording()
        print("13 recording checks passed")
    }
    private func testSilenceIsWrittenIncrementally() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("silence.wav")
        let source = try SourceAudioFile(url: url)
        for tick in 1...600 {
            try source.appendSilence(until: Double(tick) / 10)
            precondition(abs(source.duration - Double(tick) / 10) < 0.0001)
        }
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as! NSNumber
        precondition(size.intValue >= 59 * 16000 * 2, "Silence deferred until finish")
        try source.append(tone(seconds: 0.2), seconds: 60)
        try source.finish(duration: 60.2)
        let data = try read(url)
        precondition(data.frameLength == 963200)
        precondition(rms(data, start: 0, end: 60) == 0)
        precondition(rms(data, start: 60.05, end: 60.15) > 0.1)
    }
    private func testMutedBuffersAndArchivesRemainSilent() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let files = try SourceAudioFiles(outputURL: directory.appendingPathComponent("mute.m4a"), archiveAudio: true)
        files.start()
        let epoch = CMClockGetTime(CMClockGetHostTimeClock())
        func time(_ value: Double) -> CMTime { CMTimeAdd(epoch, CMTime(seconds: value, preferredTimescale: 48000)) }
        files.append(tone(seconds: 0.2), timestamp: time(0), microphone: true)
        files.setMicrophoneMuted(true, at: time(0.25))
        files.setMicrophoneMuted(false, at: time(0.75))
        // A delayed buffer captured while muted must remain silent after unmute.
        files.append(tone(seconds: 0.2), timestamp: time(0.4), microphone: true)
        files.append(tone(seconds: 0.2), timestamp: time(0.4), microphone: false)
        files.append(tone(seconds: 0.2), timestamp: time(0.8), microphone: true)
        files.setMicrophoneMuted(true, at: time(1.0))
        files.append(tone(seconds: 0.2), timestamp: time(1.1), microphone: true)
        try files.finish(duration: 1.5)
        let host = try read(directory.appendingPathComponent("raw/mute.host_record.wav"))
        let remote = try read(directory.appendingPathComponent("raw/mute.remote_record.wav"))
        precondition(host.frameLength == 24000 && remote.frameLength == 24000)
        precondition(rms(host, start: 0.45, end: 0.55) == 0)
        precondition(rms(host, start: 1.1, end: 1.4) == 0)
        precondition(rms(host, start: 0.85, end: 0.95) > 0.1)
        precondition(rms(remote, start: 0.45, end: 0.55) > 0.1)
        let archive = try AVAudioFile(forReading: files.archiveURLs[0])
        let buffer = AVAudioPCMBuffer(pcmFormat: archive.processingFormat, frameCapacity: AVAudioFrameCount(archive.length))!
        try archive.read(into: buffer)
        for channel in 0..<2 {
            for index in 19200..<28800 { precondition(buffer.floatChannelData![channel][index] == 0) }
        }
    }

    private func testDeliveryOverflowIsBoundedAndCounted() throws {
        let delivered = DeliveryCounter()
        let delivery = AudioDelivery(capacity: 1) { _, _, _ in delivered.increment() }
        delivery.queue.suspend()
        delivery.submit(tone(seconds: 0.1), time: .zero, microphone: true)
        delivery.submit(tone(seconds: 0.2), time: CMTime(seconds: 1, preferredTimescale: 48000), microphone: false)
        delivery.queue.resume()
        do { try delivery.drain(); preconditionFailure("Overflow hidden") }
        catch let error as CaptureFailure {
            precondition(error.report.droppedBuffers == 1)
            precondition(abs(error.report.droppedSourceSeconds - 0.2) < 0.001)
            precondition(error.report.losses.count == 1 && !error.report.losses[0].microphone)
        }
        precondition(delivered.count == 1)
        delivery.submit(tone(seconds: 0.1), time: .zero, microphone: true)
        try? delivery.drain()
        precondition(delivered.count == 2, "Overflow must not stop subsequent delivery")
    }

    private func testCaptureWarningStillProducesRecording() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("partial.m4a")
        let files = try SourceAudioFiles(outputURL: output, archiveAudio: true)
        files.start()
        let epoch = CMClockGetTime(CMClockGetHostTimeClock())
        files.append(tone(seconds: 0.2), timestamp: epoch, microphone: true)
        try files.finish(duration: 1)
        let failure = CaptureFailure(report: CaptureReport(droppedBuffers: 1, droppedSourceSeconds: 0.1,
            losses: [CaptureLoss(microphone: true, timestamp: epoch.seconds + 0.5, duration: 0.1)]))
        let result = await finishRecording(sourceFiles: files, outputURL: output, outputKind: .m4a,
                                          duration: 1, startedAt: epoch, captureError: failure)
        precondition(result.fileSize > 0 && result.warnings.count == 1)
        precondition(files.archiveURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
        let report = try JSONDecoder().decode(CaptureReport.self,
            from: Data(contentsOf: directory.appendingPathComponent("raw/partial.capture-report.json")))
        precondition(abs(report.losses[0].timestamp - 0.5) < 0.001)
        let failedExport = await finishRecording(sourceFiles: files,
            outputURL: directory.appendingPathComponent("absent/result.m4a"), outputKind: .m4a,
            duration: 1, startedAt: epoch, captureError: nil)
        precondition(!failedExport.warnings.isEmpty)
        precondition(files.archiveURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func testAudioOnlyMixAndArchives() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let output = directory.appendingPathComponent("mix.m4a")
        let files = try SourceAudioFiles(outputURL: output, archiveAudio: true)
        files.start()
        let epoch = CMClockGetTime(CMClockGetHostTimeClock())
        files.append(tone(seconds: 0.2), timestamp: epoch, microphone: true)
        files.append(tone(seconds: 0.2), timestamp: CMTimeAdd(epoch, CMTime(seconds: 0.5, preferredTimescale: 48000)), microphone: false)
        try files.finish(duration: 1)
        let host = try read(directory.appendingPathComponent("raw/mix.host_record.wav"))
        let remote = try read(directory.appendingPathComponent("raw/mix.remote_record.wav"))
        precondition(host.frameLength == 16000 && remote.frameLength == host.frameLength)
        precondition(rms(remote, start: 0.1, end: 0.4) < 0.005)
        precondition(rms(remote, start: 0.52, end: 0.65) > 0.1)
        for url in files.archiveURLs {
            let file = try AVAudioFile(forReading: url)
            precondition(file.fileFormat.sampleRate == 48000 && file.fileFormat.channelCount == 2)
            precondition(file.length == 48000)
        }
        try await exportMixedAudio(from: files.archiveURLs, to: output)
        let asset = AVURLAsset(url: output)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        let duration = try await asset.load(.duration).seconds
        precondition(video.isEmpty && audio.count == 1 && abs(duration - 1) < 0.05)
        let mp4 = directory.appendingPathComponent("mix.mp4")
        try await exportMixedAudio(from: files.archiveURLs, to: mp4, outputKind: .mp4)
        let mp4Video = try await AVURLAsset(url: mp4).loadTracks(withMediaType: .video)
        precondition(mp4Video.isEmpty)
        do {
            try await exportMixedAudio(from: files.archiveURLs, to: output)
            preconditionFailure("Existing mixed recording overwritten")
        } catch SourceAudioError.existingFile {}
        precondition(files.archiveURLs.allSatisfy { FileManager.default.fileExists(atPath: $0.path) })
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
        formatter.dateFormat = "yyyy-MM/dd/'meeting_'yyyy-MM-dd_HH-mm-ss/'meeting_'yyyy-MM-dd_HH-mm-ss'.m4a'"
        precondition(path.path == directory.appendingPathComponent(formatter.string(from: date)).path)
        precondition(FileManager.default.fileExists(atPath: path.deletingLastPathComponent().path))
        do {
            _ = try RecordingPaths.makeOutputURL(outputDirectory: directory, date: date)
            preconditionFailure("Existing meeting directory accepted")
        } catch {}
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

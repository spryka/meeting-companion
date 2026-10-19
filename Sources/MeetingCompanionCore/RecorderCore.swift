import AVFoundation
import CoreMedia
import Foundation

public enum OutputKind {
    case m4a
    case mp4

    public var fileExtension: String {
        switch self {
        case .m4a:
            return "m4a"
        case .mp4:
            return "mp4"
        }
    }
}

public struct RecordingResult: Sendable {
    public let outputURL: URL
    public let duration: TimeInterval
    public let fileSize: Int
    public let warnings: [String]
}

public struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

public enum Microphones {
    public static func available() -> [MicrophoneDevice] {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        )

        return discoverySession.devices.map { device in
            MicrophoneDevice(id: device.uniqueID, name: device.localizedName)
        }
    }
}

public struct RecordingPaths {
    public static var defaultOutputDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Downloads")
            .appendingPathComponent("Meetings")
    }

    public static func makeOutputURL(outputDirectory: URL, outputKind: OutputKind = .m4a, date: Date = Date()) throws -> URL {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM/dd"
        let directory = outputDirectory.appendingPathComponent(formatter.string(from: date))
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let name = "meeting_\(formatter.string(from: date))"
        let meetingDirectory = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: meetingDirectory, withIntermediateDirectories: false)
        return meetingDirectory.appendingPathComponent(name).appendingPathExtension(outputKind.fileExtension)
    }
}

@available(macOS 15.0, *)
public final class Recorder: @unchecked Sendable {
    private let outputURL: URL
    private let outputKind: OutputKind
    private let sourceFiles: SourceAudioFiles
    private let queue = DispatchQueue(label: "local.meeting-companion.sources")
    private var capture: (any AudioCapture)?
    private var startedAt: CMTime?
    private var lastMic = Date.distantPast
    private var lastSystem = Date.distantPast
    private let onLevels: (@Sendable (Double, Double) -> Void)?

    public init(outputURL: URL, outputKind: OutputKind = .m4a,
                microphoneDeviceID: String? = nil,
                backend: AudioCaptureBackend = .screenCaptureKit,
                onLevels: (@Sendable (Double, Double) -> Void)? = nil) async throws {
        guard !FileManager.default.fileExists(atPath: outputURL.path) else { throw SourceAudioError.existingFile(outputURL.path) }
        self.outputURL = outputURL
        self.outputKind = outputKind
        self.onLevels = onLevels
        sourceFiles = try SourceAudioFiles(outputURL: outputURL, archiveAudio: true)
        capture = try await makeAudioCapture(backend: backend, microphoneID: microphoneDeviceID) { [weak self] buffer, time, microphone in
            guard let self else { return }
            self.queue.sync {
                self.sourceFiles.append(buffer, timestamp: time, microphone: microphone)
                guard let onLevels = self.onLevels else { return }
                let now = Date()
                if microphone {
                    guard now.timeIntervalSince(self.lastMic) >= 0.2 else { return }
                    self.lastMic = now
                    onLevels(audioLevel(from: buffer), .nan)
                } else {
                    guard now.timeIntervalSince(self.lastSystem) >= 0.2 else { return }
                    self.lastSystem = now
                    onLevels(.nan, audioLevel(from: buffer))
                }
            }
        }
    }

    public func setMicrophoneMuted(_ muted: Bool) {
        let requestedAt = CMClockGetTime(CMClockGetHostTimeClock())
        queue.sync { sourceFiles.setMicrophoneMuted(muted, at: requestedAt) }
    }

    public func start() async throws {
        guard let capture else { throw RecorderError.notConfigured }
        startedAt = CMClockGetTime(CMClockGetHostTimeClock())
        queue.sync { sourceFiles.start() }
        do { try await capture.start() }
        catch {
            try? await capture.stop()
            queue.sync { sourceFiles.pause() }
            self.capture = nil
            throw error
        }
    }

    public func stop() async throws -> RecordingResult {
        guard let capture, let startedAt else { throw RecorderError.notConfigured }
        var captureError: Error?
        do { try await capture.stop() } catch { captureError = error }
        self.capture = nil
        let duration = CMTimeGetSeconds(CMTimeSubtract(CMClockGetTime(CMClockGetHostTimeClock()), startedAt))
        // Finalize all captured audio even when the backend reports a partial recording.
        try queue.sync { try sourceFiles.finish(duration: duration) }
        return await finishRecording(sourceFiles: sourceFiles, outputURL: outputURL, outputKind: outputKind,
                                     duration: duration, startedAt: startedAt, captureError: captureError)
    }
}

// Source files have already been finalized; a capture warning must not discard them.
func finishRecording(sourceFiles: SourceAudioFiles, outputURL: URL, outputKind: OutputKind,
                     duration: Double, startedAt: CMTime, captureError: Error?) async -> RecordingResult {
    var warnings: [String] = []
    var report = (captureError as? CaptureFailure)?.report ?? CaptureReport(failure: captureError?.localizedDescription)
    report.losses = report.losses.map {
        CaptureLoss(microphone: $0.microphone, timestamp: max(0, $0.timestamp - startedAt.seconds), duration: $0.duration)
    }
    if let warning = report.warning { warnings.append(warning) }
    let reportURL = outputURL.deletingLastPathComponent().appendingPathComponent("raw")
        .appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent + ".capture-report.json")
    do {
        try await exportMixedAudio(from: sourceFiles.archiveURLs, to: outputURL, outputKind: outputKind)
    } catch {
        report.exportFailure = error.localizedDescription
        warnings.append("Общая запись не собрана; исходные дорожки сохранены: " + error.localizedDescription)
    }
    do {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(report).write(to: reportURL, options: .atomic)
    } catch { warnings.append("Не удалось сохранить журнал захвата: " + error.localizedDescription) }
    if warnings.isEmpty {
        for url in sourceFiles.archiveURLs { try? FileManager.default.removeItem(at: url) }
    }
    return RecordingResult(outputURL: outputURL, duration: duration, fileSize: fileSize(at: outputURL), warnings: warnings)
}

@available(macOS 15.0, *)
public final class AudioLevelMonitor: @unchecked Sendable {
    private var capture: (any AudioCapture)?
    private let onLevels: @Sendable (Double, Double) -> Void
    private var lastMic = Date.distantPast
    private var lastSystem = Date.distantPast

    public init(microphoneDeviceID: String? = nil, backend: AudioCaptureBackend = .screenCaptureKit,
                onLevels: @escaping @Sendable (Double, Double) -> Void) async throws {
        self.onLevels = onLevels
        capture = try await makeAudioCapture(backend: backend, microphoneID: microphoneDeviceID) { [weak self] buffer, _, microphone in
            guard let self else { return }
            let now = Date()
            if microphone {
                guard now.timeIntervalSince(lastMic) >= 0.2 else { return }
                lastMic = now
                onLevels(audioLevel(from: buffer), .nan)
            } else {
                guard now.timeIntervalSince(lastSystem) >= 0.2 else { return }
                lastSystem = now
                onLevels(.nan, audioLevel(from: buffer))
            }
        }
    }

    public func start() async throws { try await capture?.start() }
    public func stop() async throws {
        let capture = capture
        self.capture = nil
        try await capture?.stop()
    }
}

public func exportMixedAudio(from sources: [URL], to output: URL, outputKind: OutputKind = .m4a) async throws {
    guard !FileManager.default.fileExists(atPath: output.path) else { throw SourceAudioError.existingFile(output.path) }
    let composition = AVMutableComposition()
    var parameters: [AVMutableAudioMixInputParameters] = []
    for url in sources {
        let asset = AVURLAsset(url: url)
        guard let source = try await asset.loadTracks(withMediaType: .audio).first,
              let track = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw RecorderError.exportUnavailable
        }
        let duration = try await asset.load(.duration)
        try track.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: source, at: .zero)
        let parameter = AVMutableAudioMixInputParameters(track: track)
        parameter.setVolume(0.5, at: .zero)
        parameters.append(parameter)
    }
    guard !parameters.isEmpty else { throw RecorderError.exportUnavailable }
    let mix = AVMutableAudioMix()
    mix.inputParameters = parameters
    guard let session = AVAssetExportSession(asset: composition,
        presetName: outputKind == .m4a ? AVAssetExportPresetAppleM4A : AVAssetExportPresetHighestQuality) else {
        throw RecorderError.exportUnavailable
    }
    session.audioMix = mix
    let temporary = output.deletingLastPathComponent().appendingPathComponent("." + UUID().uuidString + "." + outputKind.fileExtension)
    defer { try? FileManager.default.removeItem(at: temporary) }
    try await session.export(to: temporary, as: outputKind == .m4a ? .m4a : .mp4)
    try FileManager.default.moveItem(at: temporary, to: output)
}

func audioLevel(from buffer: AVAudioPCMBuffer) -> Double {
    var sum = 0.0
    var count = 0
    for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
        guard let data = audio.mData else { continue }
        accumulateAudioSamples(data: data, byteCount: Int(audio.mDataByteSize),
            audioFormat: buffer.format.streamDescription.pointee, sumSquares: &sum, sampleCount: &count)
    }
    return count == 0 ? 0 : min(sqrt(sum / Double(count)) * 6, 1)
}

actor AsyncSignal {
    private var continuation: CheckedContinuation<Void, Error>?
    private var result: Result<Void, Error>?

    func wait() async throws {
        if let result { return try result.get() }

        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
        }
    }

    func signal(error: Error? = nil) {
        guard result == nil else { return }
        let outcome: Result<Void, Error> = error.map { .failure($0) } ?? .success(())
        result = outcome
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: outcome)
    }
}

public enum RecorderError: LocalizedError {
    case noDisplay
    case notConfigured
    case missingValue(String)
    case invalidValue(String, String)
    case unknownArgument(String)
    case unsupportedFileType(String, String)
    case exportUnavailable
    case exportFailed

    public var errorDescription: String? {
        switch self {
        case .noDisplay:
            return "Не найден экран для записи системного звука."
        case .notConfigured:
            return "Запись ещё не настроена."
        case .missingValue(let argument):
            return "Missing value for \(argument)."
        case .invalidValue(let argument, let value):
            return "Invalid value for \(argument): \(value)."
        case .unknownArgument(let argument):
            return "Unknown argument: \(argument). Use --help."
        case .unsupportedFileType(let requested, let supported):
            return "Unsupported output file type: \(requested). Supported types: \(supported)"
        case .exportUnavailable:
            return "Не удалось подготовить сохранение звука в M4A."
        case .exportFailed:
            return "Не удалось сохранить звук в M4A."
        }
    }
}

public func exportAudioToM4A(from sourceURL: URL, to outputURL: URL) async throws {
    guard !FileManager.default.fileExists(atPath: outputURL.path) else {
        throw SourceAudioError.existingFile(outputURL.path)
    }

    let asset = AVURLAsset(url: sourceURL)
    guard let exportSession = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetAppleM4A) else {
        throw RecorderError.exportUnavailable
    }

    exportSession.outputURL = outputURL
    exportSession.outputFileType = .m4a
    try await exportSession.export(to: outputURL, as: .m4a)
}

public func formatDuration(_ seconds: TimeInterval) -> String {
    let rounded = Int(seconds.rounded())
    let hours = rounded / 3600
    let minutes = (rounded % 3600) / 60
    let seconds = rounded % 60

    if hours > 0 {
        return "\(hours)h \(String(format: "%02d", minutes))m \(String(format: "%02d", seconds))s"
    }

    return "\(minutes)m \(String(format: "%02d", seconds))s"
}

public func formatClock(_ seconds: TimeInterval) -> String {
    let rounded = Int(seconds.rounded())
    let hours = rounded / 3600
    let minutes = (rounded % 3600) / 60
    let seconds = rounded % 60

    if hours > 0 {
        return "\(hours):\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
    }

    return "\(String(format: "%02d", minutes)):\(String(format: "%02d", seconds))"
}

public func formatBytes(_ bytes: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
}

public func fileSize(at url: URL) -> Int {
    let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
    return attributes?[.size] as? Int ?? 0
}

func audioLevel(from sampleBuffer: CMSampleBuffer) -> Double {
    guard CMSampleBufferDataIsReady(sampleBuffer) else { return 0 }

    var bufferListSize = 0
    CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: &bufferListSize,
        bufferListOut: nil,
        bufferListSize: 0,
        blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil,
        flags: 0,
        blockBufferOut: nil
    )

    if bufferListSize == 0 {
        bufferListSize = MemoryLayout<AudioBufferList>.size + MemoryLayout<AudioBuffer>.size * 7
    }

    let bufferListStorage = UnsafeMutableRawPointer.allocate(
        byteCount: bufferListSize,
        alignment: MemoryLayout<AudioBufferList>.alignment
    )
    defer { bufferListStorage.deallocate() }

    let audioBufferList = bufferListStorage.bindMemory(to: AudioBufferList.self, capacity: 1)
    var blockBuffer: CMBlockBuffer?

    let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
        sampleBuffer,
        bufferListSizeNeededOut: nil,
        bufferListOut: audioBufferList,
        bufferListSize: bufferListSize,
        blockBufferAllocator: nil,
        blockBufferMemoryAllocator: nil,
        flags: 0,
        blockBufferOut: &blockBuffer
    )
    guard status == noErr else { return 0 }

    let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
    let audioFormat = CMSampleBufferGetFormatDescription(sampleBuffer)
        .flatMap { CMAudioFormatDescriptionGetStreamBasicDescription($0)?.pointee }
    var sumSquares = 0.0
    var sampleCount = 0

    for buffer in buffers {
        guard let data = buffer.mData else { continue }
        accumulateAudioSamples(
            data: data,
            byteCount: Int(buffer.mDataByteSize),
            audioFormat: audioFormat,
            sumSquares: &sumSquares,
            sampleCount: &sampleCount
        )
    }

    guard sampleCount > 0 else { return 0 }
    let rms = sqrt(sumSquares / Double(sampleCount))
    return min(max(rms * 6, 0), 1)
}

private func accumulateAudioSamples(
    data: UnsafeMutableRawPointer,
    byteCount: Int,
    audioFormat: AudioStreamBasicDescription?,
    sumSquares: inout Double,
    sampleCount: inout Int
) {
    guard byteCount > 0 else { return }

    let formatID = audioFormat?.mFormatID ?? kAudioFormatLinearPCM
    let formatFlags = audioFormat?.mFormatFlags ?? kAudioFormatFlagIsFloat
    let bytesPerSample = max(1, Int((audioFormat?.mBitsPerChannel ?? 32) / 8))
    let isLinearPCM = formatID == kAudioFormatLinearPCM
    let isFloat = isLinearPCM && (formatFlags & kAudioFormatFlagIsFloat) != 0
    let isSignedInteger = isLinearPCM && (formatFlags & kAudioFormatFlagIsSignedInteger) != 0

    if isFloat && bytesPerSample == MemoryLayout<Float>.size {
        let count = byteCount / MemoryLayout<Float>.size
        let samples = data.bindMemory(to: Float.self, capacity: count)
        for index in 0..<count {
            accumulate(Double(samples[index]), sumSquares: &sumSquares, sampleCount: &sampleCount)
        }
        return
    }

    if isFloat && bytesPerSample == MemoryLayout<Double>.size {
        let count = byteCount / MemoryLayout<Double>.size
        let samples = data.bindMemory(to: Double.self, capacity: count)
        for index in 0..<count {
            accumulate(samples[index], sumSquares: &sumSquares, sampleCount: &sampleCount)
        }
        return
    }

    if isSignedInteger && bytesPerSample == MemoryLayout<Int16>.size {
        let count = byteCount / MemoryLayout<Int16>.size
        let samples = data.bindMemory(to: Int16.self, capacity: count)
        for index in 0..<count {
            accumulate(Double(samples[index]) / Double(Int16.max), sumSquares: &sumSquares, sampleCount: &sampleCount)
        }
        return
    }

    if isSignedInteger && bytesPerSample == MemoryLayout<Int32>.size {
        let count = byteCount / MemoryLayout<Int32>.size
        let samples = data.bindMemory(to: Int32.self, capacity: count)
        for index in 0..<count {
            accumulate(Double(samples[index]) / Double(Int32.max), sumSquares: &sumSquares, sampleCount: &sampleCount)
        }
        return
    }

    let count = byteCount / MemoryLayout<Float>.size
    let samples = data.bindMemory(to: Float.self, capacity: count)
    for index in 0..<count {
        accumulate(Double(samples[index]), sumSquares: &sumSquares, sampleCount: &sampleCount)
    }
}

private func accumulate(_ sample: Double, sumSquares: inout Double, sampleCount: inout Int) {
    guard sample.isFinite else { return }
    sumSquares += sample * sample
    sampleCount += 1
}

public let permissionHint = """

If this is the first run, grant permissions in System Settings:
  Privacy & Security -> Screen & System Audio Recording
  Privacy & Security -> Microphone

When running from Terminal, the permission is usually granted to Terminal.app.
After changing permissions, quit and reopen Terminal before retrying.
"""

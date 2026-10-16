import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

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
        let filename = "meeting_\(formatter.string(from: date)).\(outputKind.fileExtension)"

        return directory.appendingPathComponent(filename)
    }
}

@available(macOS 15.0, *)
public final class Recorder: NSObject, SCRecordingOutputDelegate, SCStreamOutput, @unchecked Sendable {
    private let outputURL: URL
    private let outputKind: OutputKind
    private let microphoneDeviceID: String?
    private let onLevels: (@Sendable (Double, Double) -> Void)?
    private let recordingURL: URL
    private let finished = AsyncSignal()
    private let audioQueue = DispatchQueue(label: "local.meeting-companion.sources")
    private let sourceFiles: SourceAudioFiles
    private var stream: SCStream?
    private var recordingOutput: SCRecordingOutput?
    private var recordedDuration: TimeInterval = 0
    private var lastSystemLevelEmit = Date.distantPast
    private var lastMicrophoneLevelEmit = Date.distantPast

    public init(
        outputURL: URL,
        outputKind: OutputKind = .m4a,
        microphoneDeviceID: String? = nil,
        onLevels: (@Sendable (Double, Double) -> Void)? = nil
    ) async throws {
        self.outputURL = outputURL
        self.outputKind = outputKind
        self.microphoneDeviceID = microphoneDeviceID
        self.onLevels = onLevels
        self.sourceFiles = try SourceAudioFiles(outputURL: outputURL)
        self.recordingURL = outputKind == .m4a
            ? outputURL.deletingPathExtension().appendingPathExtension("recording-tmp.mp4")
            : outputURL
        super.init()
        for path in [outputURL, recordingURL] where FileManager.default.fileExists(atPath: path.path) {
            throw SourceAudioError.existingFile(path.path)
        }
        try await configure()
    }

    private func configure() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = false

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphoneDeviceID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)

        let recordingConfiguration = SCRecordingOutputConfiguration()
        recordingConfiguration.outputURL = recordingURL
        guard recordingConfiguration.availableOutputFileTypes.contains(.mp4) else {
            throw RecorderError.unsupportedFileType(
                AVFileType.mp4.rawValue,
                recordingConfiguration.availableOutputFileTypes.map(\.rawValue).joined(separator: ", ")
            )
        }
        recordingConfiguration.outputFileType = .mp4

        let recordingOutput = SCRecordingOutput(configuration: recordingConfiguration, delegate: self)
        try stream.addRecordingOutput(recordingOutput)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: audioQueue)

        self.stream = stream
        self.recordingOutput = recordingOutput
    }

    public func start() async throws {
        guard let stream else { throw RecorderError.notConfigured }
        audioQueue.sync { sourceFiles.start() }
        try await stream.startCapture()
    }

    public func stop() async throws -> RecordingResult {
        guard let stream else { throw RecorderError.notConfigured }
        audioQueue.sync { sourceFiles.pause() }
        if let recordingOutput {
            try stream.removeRecordingOutput(recordingOutput)
            do { try await finished.wait() }
            catch {
                try? await stream.stopCapture()
                throw error
            }
        }
        try await stream.stopCapture()
        if outputKind == .m4a {
            try await exportAudioToM4A(from: recordingURL, to: outputURL)
            try? FileManager.default.removeItem(at: recordingURL)
        }
        // Finalize sidecars after the original recording is safely saved.
        try audioQueue.sync { try sourceFiles.finish(duration: recordedDuration) }

        return RecordingResult(
            outputURL: outputURL,
            duration: recordedDuration,
            fileSize: fileSize(at: outputURL)
        )
    }

    public func recordingOutputDidStartRecording(_ recordingOutput: SCRecordingOutput) {}

    public func recordingOutput(_ recordingOutput: SCRecordingOutput, didFailWithError error: Error) {
        let finished = finished
        Task { await finished.signal(error: error) }
    }

    public func recordingOutputDidFinishRecording(_ recordingOutput: SCRecordingOutput) {
        recordedDuration = CMTimeGetSeconds(recordingOutput.recordedDuration)
        let finished = finished
        Task { await finished.signal() }
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        sourceFiles.append(sampleBuffer, microphone: type == .microphone)
        emitLevel(from: sampleBuffer, type: type)
    }

    private func emitLevel(from sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        let now = Date()

        switch type {
        case .audio:
            guard now.timeIntervalSince(lastSystemLevelEmit) >= 0.2 else { return }
            lastSystemLevelEmit = now
            onLevels?(Double.nan, audioLevel(from: sampleBuffer))
        case .microphone:
            guard now.timeIntervalSince(lastMicrophoneLevelEmit) >= 0.2 else { return }
            lastMicrophoneLevelEmit = now
            onLevels?(audioLevel(from: sampleBuffer), Double.nan)
        default:
            break
        }
    }
}

@available(macOS 15.0, *)
public final class AudioLevelMonitor: NSObject, SCStreamOutput, @unchecked Sendable {
    private let microphoneDeviceID: String?
    private let onLevels: (@Sendable (Double, Double) -> Void)
    private var stream: SCStream?
    private var lastSystemLevelEmit = Date.distantPast
    private var lastMicrophoneLevelEmit = Date.distantPast

    public init(
        microphoneDeviceID: String? = nil,
        onLevels: @escaping @Sendable (Double, Double) -> Void
    ) async throws {
        self.microphoneDeviceID = microphoneDeviceID
        self.onLevels = onLevels
        super.init()
        try await configure()
    }

    private func configure() async throws {
        let content = try await SCShareableContent.current
        guard let display = content.displays.first else {
            throw RecorderError.noDisplay
        }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        filter.includeMenuBar = false

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 1
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        configuration.microphoneCaptureDeviceID = microphoneDeviceID
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2

        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: DispatchQueue(label: "local.meeting-companion.monitor.system"))
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: DispatchQueue(label: "local.meeting-companion.monitor.microphone"))
        self.stream = stream
    }

    public func start() async throws {
        guard let stream else { throw RecorderError.notConfigured }
        try await stream.startCapture()
    }

    public func stop() async throws {
        guard let stream else { return }
        try await stream.stopCapture()
        self.stream = nil
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio || type == .microphone else { return }
        emitLevel(from: sampleBuffer, type: type)
    }

    private func emitLevel(from sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
        let now = Date()

        switch type {
        case .audio:
            guard now.timeIntervalSince(lastSystemLevelEmit) >= 0.2 else { return }
            lastSystemLevelEmit = now
            onLevels(Double.nan, audioLevel(from: sampleBuffer))
        case .microphone:
            guard now.timeIntervalSince(lastMicrophoneLevelEmit) >= 0.2 else { return }
            lastMicrophoneLevelEmit = now
            onLevels(audioLevel(from: sampleBuffer), Double.nan)
        default:
            break
        }
    }
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

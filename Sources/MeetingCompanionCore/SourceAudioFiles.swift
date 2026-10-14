import AVFoundation
import CoreMedia
import Foundation

// Accessed only on Recorder's serial audio queue.
final class SourceAudioFiles {
    private let host: SourceAudioFile
    private let remote: SourceAudioFile
    private var startTime: CMTime?
    private var recording = false
    private var failure: Error?

    init(outputURL: URL) throws {
        host = try SourceAudioFile(url: outputURL.deletingPathExtension().appendingPathExtension("host_record.wav"))
        remote = try SourceAudioFile(url: outputURL.deletingPathExtension().appendingPathExtension("remote_record.wav"))
    }

    func start() { recording = true }
    func pause() { recording = false }

    func append(_ sample: CMSampleBuffer, microphone: Bool) {
        guard recording, failure == nil, CMSampleBufferDataIsReady(sample),
              CMSampleBufferGetNumSamples(sample) > 0 else { return }
        // Use captured timestamps: startCapture itself can take hundreds of milliseconds.
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isValid, !timestamp.isIndefinite else {
            failure = SourceAudioError.invalidBuffer
            return
        }
        if startTime == nil { startTime = timestamp }
        do {
            guard let description = CMSampleBufferGetFormatDescription(sample),
                  let buffer = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(cmAudioFormatDescription: description),
                      frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else {
                throw SourceAudioError.invalidBuffer
            }
            buffer.frameLength = buffer.frameCapacity
            let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0,
                frameCount: Int32(buffer.frameLength), into: buffer.mutableAudioBufferList)
            guard status == noErr else { throw SourceAudioError.invalidBuffer }
            let offset = CMTimeGetSeconds(CMTimeSubtract(timestamp, startTime!))
            try (microphone ? host : remote).append(buffer, seconds: offset)
        } catch {
            failure = error
        }
    }

    func finish(duration: TimeInterval) throws {
        defer { startTime = nil; recording = false }
        var finishError: Error?
        let duration = max(duration, host.duration, remote.duration)
        for source in [host, remote] {
            do { try source.finish(duration: duration) } catch { finishError = error }
        }
        if let error = failure ?? finishError { throw error }
    }
}

enum SourceAudioError: LocalizedError {
    case invalidBuffer
    case existingFile(String)
    var errorDescription: String? {
        switch self {
        case .invalidBuffer: return "Некорректные звуковые данные или время записи."
        case .existingFile(let path): return "Файл уже существует: \(path)"
        }
    }
}

final class SourceAudioFile {
    private let url: URL
    private var file: AVAudioFile?
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    private var converter: AVAudioConverter?
    private var position: AVAudioFramePosition = 0
    var duration: Double { Double(position) / format.sampleRate }

    init(url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SourceAudioError.existingFile(url.path)
        }
        self.url = url
    }

    func append(_ input: AVAudioPCMBuffer, seconds: Double) throws {
        guard seconds.isFinite, seconds >= -1, seconds < 86400 else { throw SourceAudioError.invalidBuffer }
        if file == nil { try open() }
        if converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: format)
            converter?.primeMethod = .none
        }
        guard let converter,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity:
                AVAudioFrameCount(ceil(Double(input.frameLength) * 16000 / input.format.sampleRate)) + 32)
        else { throw SourceAudioError.invalidBuffer }
        var supplied = false
        var conversionError: NSError?
        let status = converter.convert(to: buffer, error: &conversionError) { _, state in
            if supplied { state.pointee = .noDataNow; return nil }
            supplied = true
            state.pointee = .haveData
            return input
        }
        if let conversionError { throw conversionError }
        guard status != .error else { throw SourceAudioError.invalidBuffer }
        let target = AVAudioFramePosition((seconds * format.sampleRate).rounded())
        try pad(to: max(0, target))
        // Trim overlapping/early buffers instead of shifting the next source in time.
        let skip = min(Int64(buffer.frameLength), max(0, position - target))
        guard skip < buffer.frameLength else { return }
        if skip > 0 {
            for audio in UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList) {
                let bytesPerFrame = Int(audio.mDataByteSize) / Int(buffer.frameLength)
                if let data = audio.mData {
                    memmove(data, data.advanced(by: Int(skip) * bytesPerFrame),
                            (Int(buffer.frameLength) - Int(skip)) * bytesPerFrame)
                }
            }
            buffer.frameLength -= AVAudioFrameCount(skip)
        }
        try file!.write(from: buffer)
        position += Int64(buffer.frameLength)
    }

    func finish(duration: Double) throws {
        defer { file = nil }
        guard duration.isFinite, duration >= 0, duration < 86400 else { throw SourceAudioError.invalidBuffer }
        if file == nil { try open() }
        try pad(to: AVAudioFramePosition((duration * format.sampleRate).rounded()))
    }

    private func open() throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 16000,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func pad(to target: AVAudioFramePosition) throws {
        guard let file else { return }
        guard let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw SourceAudioError.invalidBuffer
        }
        for audio in UnsafeMutableAudioBufferListPointer(silence.mutableAudioBufferList) {
            if let data = audio.mData { memset(data, 0, Int(audio.mDataByteSize)) }
        }
        while position < target {
            silence.frameLength = AVAudioFrameCount(min(4096, target - position))
            try file.write(from: silence)
            position += Int64(silence.frameLength)
        }
    }
}

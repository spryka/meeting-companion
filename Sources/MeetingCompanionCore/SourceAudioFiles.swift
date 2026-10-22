import AVFoundation
import CoreMedia
import Foundation

// Accessed only on Recorder's serial audio queue.
final class SourceAudioFiles {
    private let host: SourceAudioFile
    private let remote: SourceAudioFile
    private var startTime: CMTime?
    private var recording = false
    private var muteIntervals: [(start: Double, end: Double)] = []

    func setMicrophoneMuted(_ muted: Bool, at timestamp: CMTime) {
        let time = timestamp.seconds
        if muted {
            if muteIntervals.last?.end != .infinity { muteIntervals.append((time, .infinity)) }
        } else if muteIntervals.last?.end == .infinity {
            muteIntervals[muteIntervals.count - 1].end = time
        }
    }
    private var failure: Error?
    private let archive: [SourceAudioFile]
    let archiveURLs: [URL]

    init(outputURL: URL, archiveAudio: Bool = false) throws {
        let raw = outputURL.deletingLastPathComponent().appendingPathComponent("raw")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        let base = raw.appendingPathComponent(outputURL.deletingPathExtension().lastPathComponent)
        host = try SourceAudioFile(url: base.appendingPathExtension("host_record.wav"))
        remote = try SourceAudioFile(url: base.appendingPathExtension("remote_record.wav"))
        archiveURLs = archiveAudio ? ["host", "remote"].map {
            base.appendingPathExtension($0 + ".capture.caf")
        } : []
        archive = try archiveURLs.map { try SourceAudioFile(url: $0, sampleRate: 48000, channels: 2) }
    }

    func start() { startTime = CMClockGetTime(CMClockGetHostTimeClock()); recording = true }
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
            append(buffer, timestamp: timestamp, microphone: microphone)
        } catch {
            failure = error
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, timestamp: CMTime, microphone: Bool) {
        guard recording, failure == nil else { return }
        if startTime == nil { startTime = timestamp }
        let bufferStart = timestamp.seconds
        let bufferEnd = bufferStart + Double(buffer.frameLength) / buffer.format.sampleRate
        do {
            let offset = CMTimeGetSeconds(CMTimeSubtract(timestamp, startTime!))
            if microphone && muteIntervals.contains(where: { $0.start < bufferEnd && $0.end > bufferStart }) {
                // Write silence incrementally so a long mute never creates a large catch-up write.
                let end = offset + Double(buffer.frameLength) / buffer.format.sampleRate
                try host.appendSilence(until: max(0, end))
                if !archive.isEmpty { try archive[0].appendSilence(until: max(0, end)) }
                return
            }
            try (microphone ? host : remote).append(buffer, seconds: offset)
            if !archive.isEmpty { try archive[microphone ? 0 : 1].append(buffer, seconds: offset) }
        } catch { failure = error }
    }

    func finish(duration: TimeInterval) throws {
        defer { startTime = nil; recording = false }
        var finishError: Error?
        let duration = max(duration, host.duration, remote.duration)
        for source in [host, remote] + archive {
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
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var position: AVAudioFramePosition = 0
    private var inputPosition: Double?
    private var conversionPosition: AVAudioFramePosition = 0
    var duration: Double { Double(position) / format.sampleRate }

    init(url: URL, sampleRate: Double = 16000, channels: AVAudioChannelCount = 1) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw SourceAudioError.existingFile(url.path)
        }
        self.url = url
        format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
    }

    func append(_ input: AVAudioPCMBuffer, seconds: Double) throws {
        guard seconds.isFinite, seconds >= -1, seconds < 86400 else { throw SourceAudioError.invalidBuffer }
        if file == nil { try open() }
        let target = seconds * format.sampleRate
        // Follow the continuous output clock; re-anchor if accumulated timestamp drift exceeds 2 ms.
        if converter?.inputFormat != input.format || inputPosition.map({ abs(target - $0) > format.sampleRate * 0.002 }) == true {
            try drainConverter()
            converter = AVAudioConverter(from: input.format, to: format)
            converter?.primeMethod = .none
            inputPosition = target
            conversionPosition = AVAudioFramePosition(target.rounded())
        }
        guard let converter, let inputPosition else { throw SourceAudioError.invalidBuffer }
        self.inputPosition = inputPosition + Double(input.frameLength) * format.sampleRate / input.format.sampleRate
        try convert(converter, input: input)
    }

    private func convert(_ converter: AVAudioConverter, input: AVAudioPCMBuffer?) throws {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
            throw SourceAudioError.invalidBuffer
        }
        var supplied = false
        while true {
            var conversionError: NSError?
            let status = converter.convert(to: buffer, error: &conversionError) { _, state in
                guard let input else { state.pointee = .endOfStream; return nil }
                if supplied { state.pointee = .noDataNow; return nil }
                supplied = true
                state.pointee = .haveData
                return input
            }
            if let conversionError { throw conversionError }
            guard status != .error else { throw SourceAudioError.invalidBuffer }
            let count = buffer.frameLength
            if input == nil, let inputPosition {
                buffer.frameLength = AVAudioFrameCount(min(Int64(count), max(0, Int64(inputPosition.rounded()) - conversionPosition)))
            }
            if buffer.frameLength > 0 {
                let written = buffer.frameLength
                try write(buffer, at: conversionPosition)
                conversionPosition += AVAudioFramePosition(written)
            }
            if status == .inputRanDry || status == .endOfStream { return }
            guard count > 0 else { throw SourceAudioError.invalidBuffer }
        }
    }

    private func drainConverter() throws {
        if let converter { try convert(converter, input: nil) }
        converter = nil
        inputPosition = nil
    }

    private func write(_ buffer: AVAudioPCMBuffer, at target: AVAudioFramePosition) throws {
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
        try appendSilence(until: duration)
    }

    func appendSilence(until duration: Double) throws {
        guard duration.isFinite, duration >= 0, duration < 86400 else { throw SourceAudioError.invalidBuffer }
        if file == nil { try open() }
        try drainConverter()
        try pad(to: AVAudioFramePosition((duration * format.sampleRate).rounded()))
    }

    private func open() throws {
        file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: format.sampleRate,
            AVNumberOfChannelsKey: format.channelCount,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false
        ], commonFormat: .pcmFormatFloat32, interleaved: false)
    }

    private func pad(to target: AVAudioFramePosition) throws {
        guard position < target, let file else { return }
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

import AVFoundation

/// Read through EOF with bounded memory before allowing removal of the original channels.
public func verifyRetentionMix(_ url: URL, expectedDuration: Double) throws -> Bool {
    let file = try AVAudioFile(forReading: url)
    let rate = file.processingFormat.sampleRate
    guard file.fileFormat.streamDescription.pointee.mFormatID == kAudioFormatMPEG4AAC,
          expectedDuration > 0, rate > 0,
          let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 32768) else { return false }
    var frames: Int64 = 0
    while frames < file.length {
        try Task.checkCancellation()
        let count = AVAudioFrameCount(min(Int64(buffer.frameCapacity), file.length - frames))
        try file.read(into: buffer, frameCount: count)
        guard buffer.frameLength > 0 else { return false }
        frames += Int64(buffer.frameLength)
    }
    // AAC priming and capture clock rounding can differ by a fraction of a second.
    return frames > 0 && Double(frames) / rate + 0.15 >= expectedDuration
}

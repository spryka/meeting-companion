@preconcurrency import AVFoundation
import Foundation
import MeetingCompanionCore

public enum TranscriptWaveformExtractor {
    /// Derives a bounded envelope of 120 normalized peaks from the entire audio mix off MainActor.
    /// Streams through the entire file sequentially in fixed 4096-frame buffers into targetCount bins without loading the full file into RAM.
    public static func extractEnvelope(from url: URL, targetCount: Int = TranscriptWaveform.sampleCount, sampleCount: Int? = nil) async throws -> TranscriptWaveform {
        let bins = max(1, sampleCount ?? targetCount)
        let task = Task.detached(priority: .utility) { () throws -> TranscriptWaveform in
            try Task.checkCancellation()
            let file = try AVAudioFile(forReading: url)
            let length = file.length
            guard length > 0 else { throw ExtractionError.emptyAudio }

            let format = file.processingFormat
            let channelCount = Int(format.channelCount)
            guard channelCount > 0 else { throw ExtractionError.invalidPCM }

            let chunkSize: AVAudioFrameCount = 4096
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkSize) else {
                throw ExtractionError.invalidPCM
            }

            var binPeaks = Array(repeating: Float(0.0), count: bins)
            let framesPerBin = Double(length) / Double(bins)

            var currentFrame: Int64 = 0
            while currentFrame < length {
                try Task.checkCancellation()
                let framesToRead = AVAudioFrameCount(min(Int64(chunkSize), length - currentFrame))
                try file.read(into: buffer, frameCount: framesToRead)
                let readCount = Int(buffer.frameLength)
                guard readCount > 0 else { throw ExtractionError.incompleteAudio }

                guard let channelData = buffer.floatChannelData else { throw ExtractionError.invalidPCM }
                do {
                    for f in 0..<readCount {
                        let globalFrame = currentFrame + Int64(f)
                        let binIndex = min(bins - 1, max(0, Int(Double(globalFrame) / framesPerBin)))
                        var maxSample: Float = 0.0
                        for ch in 0..<channelCount {
                            let val = abs(channelData[ch][f])
                            guard val.isFinite else { throw ExtractionError.invalidPCM }
                            if val > maxSample { maxSample = val }
                        }
                        if maxSample > binPeaks[binIndex] {
                            binPeaks[binIndex] = maxSample
                        }
                    }
                }
                currentFrame += Int64(readCount)
            }

            try Task.checkCancellation()

            let maxPeak = binPeaks.max() ?? 0.0
            if maxPeak > 0.001 {
                let normalized = binPeaks.map { min(1.0, $0 / maxPeak) }
                return TranscriptWaveform(samples: normalized)
            } else {
                return TranscriptWaveform(samples: Array(repeating: 0.0, count: bins))
            }
        }

        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private enum ExtractionError: LocalizedError {
        case emptyAudio, invalidPCM, incompleteAudio
        var errorDescription: String? {
            switch self {
            case .emptyAudio: "Аудиофайл пуст."
            case .invalidPCM: "Не удалось прочитать отсчёты аудио."
            case .incompleteAudio: "Аудиофайл прочитан не полностью."
            }
        }
    }
}

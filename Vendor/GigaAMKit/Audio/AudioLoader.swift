import Foundation
import AVFoundation

public struct AudioBuffer: Sendable {
    public let samples: [Float]
    public let sampleRate: Int

    public init(samples: [Float], sampleRate: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
    }
}

public enum AudioLoader {
    public static func loadMonoFloat32(
        url: URL,
        targetSampleRate: Int = 16_000
    ) throws -> AudioBuffer {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw GigaAMError.fileNotFound(url.path)
        }

        let file = try AVAudioFile(forReading: url)
        let sourceFormat = file.processingFormat
        let sourceFrameCount = AVAudioFrameCount(file.length)

        guard let sourceBuffer = AVAudioPCMBuffer(
            pcmFormat: sourceFormat,
            frameCapacity: sourceFrameCount
        ) else {
            throw GigaAMError.invalidArguments("Failed to allocate source audio buffer")
        }

        try file.read(into: sourceBuffer)

        // Fast path: if sample rate already matches and AVFoundation gives Float32 PCM,
        // avoid AVAudioConverter completely. This is exact for our synthetic Float32 WAV
        // and also handles mono/stereo decoded PCM without resampling.
        if Int(sourceFormat.sampleRate.rounded()) == targetSampleRate,
           let channelData = sourceBuffer.floatChannelData {
            let frameCount = Int(sourceBuffer.frameLength)
            let channelCount = Int(sourceFormat.channelCount)

            if channelCount == 1 {
                let samples = Array(
                    UnsafeBufferPointer(
                        start: channelData[0],
                        count: frameCount
                    )
                )

                return AudioBuffer(samples: samples, sampleRate: targetSampleRate)
            }

            var samples = [Float](repeating: 0, count: frameCount)

            for channel in 0..<channelCount {
                let values = UnsafeBufferPointer(
                    start: channelData[channel],
                    count: frameCount
                )

                for index in 0..<frameCount {
                    samples[index] += values[index] / Float(channelCount)
                }
            }

            return AudioBuffer(samples: samples, sampleRate: targetSampleRate)
        }

        guard let targetFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: Double(targetSampleRate),
            channels: 1,
            interleaved: false
        ) else {
            throw GigaAMError.invalidArguments("Failed to create target AVAudioFormat")
        }

        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat) else {
            throw GigaAMError.invalidArguments(
                "Failed to create AVAudioConverter from \(sourceFormat) to \(targetFormat)"
            )
        }

        var didProvideInput = false
        var didEndInput = false

        let inputBlock: AVAudioConverterInputBlock = { _, outStatus in
            if !didProvideInput {
                didProvideInput = true
                outStatus.pointee = .haveData
                return sourceBuffer
            }

            if !didEndInput {
                didEndInput = true
                outStatus.pointee = .endOfStream
                return nil
            }

            outStatus.pointee = .noDataNow
            return nil
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(Double(sourceBuffer.frameLength) * Double(targetSampleRate) / sourceFormat.sampleRate) + 1024)

        while true {
            guard let outputBuffer = AVAudioPCMBuffer(
                pcmFormat: targetFormat,
                frameCapacity: 4096
            ) else {
                throw GigaAMError.invalidArguments("Failed to allocate output audio buffer")
            }

            var conversionError: NSError?
            let status = converter.convert(
                to: outputBuffer,
                error: &conversionError,
                withInputFrom: inputBlock
            )

            if let conversionError {
                throw conversionError
            }

            if outputBuffer.frameLength > 0 {
                guard let channelData = outputBuffer.floatChannelData else {
                    throw GigaAMError.invalidArguments("Converted audio has no Float32 channel data")
                }

                let count = Int(outputBuffer.frameLength)
                samples.append(
                    contentsOf: UnsafeBufferPointer(
                        start: channelData[0],
                        count: count
                    )
                )
            }

            switch status {
            case .haveData:
                continue
            case .inputRanDry, .endOfStream:
                return AudioBuffer(samples: samples, sampleRate: targetSampleRate)
            case .error:
                throw GigaAMError.invalidArguments("Audio conversion failed")
            @unknown default:
                throw GigaAMError.invalidArguments("Unknown AVAudioConverter status")
            }
        }
    }
}

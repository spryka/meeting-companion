import Foundation

public struct TranscriptWaveform: Equatable, Sendable {
    public static let sampleCount = 120
    public let samples: [Float]
    public var envelope: [Float] { samples }

    public init(samples: [Float]) {
        if samples.count == Self.sampleCount {
            self.samples = samples
        } else if samples.isEmpty {
            self.samples = Self.placeholderSamples
        } else {
            self.samples = Self.resample(samples, targetCount: Self.sampleCount)
        }
    }

    /// Honest neutral placeholder baseline (0.0) without synthetic oscillation.
    public static let placeholderSamples: [Float] = Array(repeating: 0.0, count: sampleCount)

    private static func resample(_ input: [Float], targetCount: Int) -> [Float] {
        guard !input.isEmpty, targetCount > 0 else { return Array(repeating: 0.0, count: targetCount) }
        var result = [Float]()
        result.reserveCapacity(targetCount)
        for i in 0..<targetCount {
            let index = Int(Double(i) * Double(input.count) / Double(targetCount))
            result.append(input[min(index, input.count - 1)])
        }
        return result
    }
}

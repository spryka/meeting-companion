import Foundation
import MLX

// DSP adapter for the pinned Python BF16 checkpoint; the ready network is reused.
final class BaselineMelExtractor {
    private let window: MLXArray
    private let filters: MLXArray

    init(weights: [String: MLXArray]) throws {
        guard let window = weights["preprocessor.window"], window.shape == [400],
              let filters = weights["preprocessor.fb"], filters.shape == [1, 128, 257],
              window.dtype == .float32, filters.dtype == .float32 else {
            throw Nemotron3DiarizationError.incompatibleWeights("missing BF16 checkpoint frontend buffers")
        }
        self.window = concatenated([MLXArray.zeros([56]), window, MLXArray.zeros([56])])
        self.filters = filters[0].transposed()
        eval(self.window, self.filters)
    }

    func extract(_ samples: [Float]) -> ([Float], Int) {
        let count = samples.count / 160
        guard count > 0 else { return ([], 0) }
        let audio = MLXArray(samples)
        func gather(_ indices: MLXArray) -> MLXArray {
            let values = audio[clip(indices, min: 0, max: samples.count - 1)]
            return MLX.where((indices .>= 0) .&& (indices .< samples.count), values, 0)
        }
        var result: [Float] = []
        result.reserveCapacity(count * 128)
        for start in stride(from: 0, to: count, by: 1024) {
            autoreleasepool {
                let ids = MLXArray(Int32(start)..<Int32(min(start + 1024, count)))
                let positions = ids.reshaped(-1, 1) * 160 + MLXArray(Int32(0)..<512).reshaped(1, -1) - 256
                var frames = gather(positions) - Float(0.97) * gather(positions - 1)
                frames = MLX.where((positions .>= 0) .&& (positions .< samples.count), frames, 0)
                let power = pow(abs(MLXFFT.rfft(frames * window)), 2)
                let features = log(matmul(power, filters) + Float(1.0 / 16777216.0))
                eval(features)
                result.append(contentsOf: features.reshaped(-1).asArray(Float.self))
            }
        }
        return (result, count)
    }
}

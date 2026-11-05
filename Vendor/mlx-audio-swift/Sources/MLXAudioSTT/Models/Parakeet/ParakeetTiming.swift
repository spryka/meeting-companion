import Foundation
import MLX

public extension ParakeetModel {
    /// Public adapter for extracting token alignment without requiring @testable imports in release builds.
    /// Preserves the required FP16 cast prior to the frontend feature extraction.
    func decodeAlignedAudio(_ audio: [Float]) -> [ParakeetAlignedResult] {
        let array = MLXArray(audio).asType(.float16)
        let (features, lengths) = makeBatchFeatures([array])
        return decode(mel: features, lengths: lengths)
    }

    /// Public adapter taking an MLXArray chunk directly, applying FP16 cast prior to feature extraction.
    func decodeAlignedChunk(_ chunk: MLXArray) -> [ParakeetAlignedResult] {
        let array = chunk.asType(.float16)
        let (features, lengths) = makeBatchFeatures([array])
        return decode(mel: features, lengths: lengths)
    }

    /// Convenience helper returning all aligned tokens across sentences.
    func decodeAlignedTokens(_ audio: [Float]) -> [ParakeetAlignedToken] {
        decodeAlignedAudio(audio).flatMap { $0.sentences.flatMap(\.tokens) }
    }
}

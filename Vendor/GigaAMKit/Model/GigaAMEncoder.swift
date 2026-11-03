import Foundation
@preconcurrency import MLX

public struct GigaAMEncoderOutput {
    public let encoded: MLXArray
    public let length: Int
}

public final class GigaAMEncoder: @unchecked Sendable {
    private let preEncoder: GigaAMPreEncoder
    private let stack: GigaAMConformerEncoderStack

    public init(store: GigaAMTensorStore, layerCount: Int = 16) throws {
        self.preEncoder = try GigaAMPreEncoder(store: store)
        self.stack = try GigaAMConformerEncoderStack(store: store, layerCount: layerCount)
    }

    public func forward(features: MLXArray, length: Int) -> GigaAMEncoderOutput {
        // Python encoder.forward:
        // audio_signal, length = pre_encode(x=audio_signal.transpose(1, 2), lengths=length)
        // ...
        // return audio_signal.transpose(1, 2), length
        //
        // features: [B, 64, T]
        // preEncode input: [B, T, 64]
        let preEncodeInput = transposed(features, 0, 2, 1)
        let preEncoded = preEncoder.forward(preEncodeInput, length: length)

        let stackOutput = stack.forward(preEncoded.encoded).output

        // stackOutput: [B, T', 768]
        // encoded:     [B, 768, T']
        let encoded = transposed(stackOutput, 0, 2, 1)

        eval(encoded)

        return GigaAMEncoderOutput(
            encoded: encoded,
            length: preEncoded.length
        )
    }
}

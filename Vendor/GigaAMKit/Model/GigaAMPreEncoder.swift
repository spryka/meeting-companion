import Foundation
@preconcurrency import MLX
@preconcurrency import MLXNN

public struct GigaAMPreEncoderOutput {
    public let encoded: MLXArray
    public let length: Int

    public init(encoded: MLXArray, length: Int) {
        self.encoded = encoded
        self.length = length
    }
}

public final class GigaAMPreEncoder: @unchecked Sendable {
    public let kernelSize: Int
    public let stride: Int
    public let padding: Int

    private let conv0Weight: MLXArray
    private let conv0Bias: MLXArray
    private let conv2Weight: MLXArray
    private let conv2Bias: MLXArray

    public init(
        store: GigaAMTensorStore,
        kernelSize: Int = 5,
        stride: Int = 2,
        padding: Int = 2
    ) throws {
        self.kernelSize = kernelSize
        self.stride = stride
        self.padding = padding

        // PyTorch Conv1d weights are [C_out, C_in, K].
        // MLX conv1d weights are [C_out, K, C_in].
        self.conv0Weight = transposed(
            try store.load("model.encoder.pre_encode.conv.0.weight"),
            0, 2, 1
        )
        self.conv0Bias = try store.load("model.encoder.pre_encode.conv.0.bias")

        self.conv2Weight = transposed(
            try store.load("model.encoder.pre_encode.conv.2.weight"),
            0, 2, 1
        )
        self.conv2Bias = try store.load("model.encoder.pre_encode.conv.2.bias")
    }

    public func forward(_ x: MLXArray, length: Int) -> GigaAMPreEncoderOutput {
        // Input x layout is already MLX-friendly:
        // [N, L, C] = [1, 99, 64]
        var y = conv1d(
            x,
            conv0Weight,
            stride: stride,
            padding: padding
        ) + conv0Bias

        y = relu(y)

        y = conv1d(
            y,
            conv2Weight,
            stride: stride,
            padding: padding
        ) + conv2Bias

        y = relu(y)
        eval(y)

        return GigaAMPreEncoderOutput(
            encoded: y,
            length: calcOutputLength(length)
        )
    }

    public func calcOutputLength(_ inputLength: Int) -> Int {
        var length = Float(inputLength)
        let addPad = Float(2 * padding - kernelSize)

        for _ in 0..<2 {
            length = floor((length + addPad) / Float(stride) + 1.0)
        }

        return Int(length)
    }
}

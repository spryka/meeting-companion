import Foundation
@preconcurrency import MLX
@preconcurrency import MLXNN

public final class GigaAMConformerConvolution: @unchecked Sendable {
    public let modelDim: Int
    public let kernelSize: Int
    public let padding: Int

    private let pointwiseConv1Weight: MLXArray
    private let pointwiseConv1Bias: MLXArray

    private let depthwiseConvWeight: MLXArray
    private let depthwiseConvBias: MLXArray

    private let convNorm: GigaAMLayerNorm

    private let pointwiseConv2Weight: MLXArray
    private let pointwiseConv2Bias: MLXArray

    public init(
        store: GigaAMTensorStore,
        prefix: String,
        modelDim: Int = 768,
        kernelSize: Int = 5,
        padding: Int = 2
    ) throws {
        self.modelDim = modelDim
        self.kernelSize = kernelSize
        self.padding = padding

        // PyTorch Conv1d weights: [C_out, C_in, K]
        // MLX conv1d weights:    [C_out, K, C_in/groups]
        self.pointwiseConv1Weight = transposed(
            try store.load("\(prefix).pointwise_conv1.weight"),
            0, 2, 1
        )
        self.pointwiseConv1Bias = try store.load("\(prefix).pointwise_conv1.bias")

        self.depthwiseConvWeight = transposed(
            try store.load("\(prefix).depthwise_conv.weight"),
            0, 2, 1
        )
        self.depthwiseConvBias = try store.load("\(prefix).depthwise_conv.bias")

        // В Python поле называется batch_norm, но для этой модели norm_type == layer_norm.
        self.convNorm = try GigaAMLayerNorm(
            store: store,
            prefix: "\(prefix).batch_norm"
        )

        self.pointwiseConv2Weight = transposed(
            try store.load("\(prefix).pointwise_conv2.weight"),
            0, 2, 1
        )
        self.pointwiseConv2Bias = try store.load("\(prefix).pointwise_conv2.bias")
    }

    public func forward(_ x: MLXArray) -> MLXArray {
        // Python:
        // x = x.transpose(1, 2)
        // x = pointwise_conv1(x)
        // x = glu(x, dim=1)
        // x = depthwise_conv(x)
        // x = layer_norm(x.transpose(1, 2)).transpose(1, 2)
        // x = silu(x)
        // x = pointwise_conv2(x)
        // return x.transpose(1, 2)
        //
        // В MLX держим layout [N, L, C], поэтому channel axis — последний.

        var y = conv1d(
            x,
            pointwiseConv1Weight,
            stride: 1,
            padding: 0
        ) + pointwiseConv1Bias

        y = glu(y, axis: -1)

        y = conv1d(
            y,
            depthwiseConvWeight,
            stride: 1,
            padding: padding,
            groups: modelDim
        ) + depthwiseConvBias

        y = convNorm.forward(y)
        y = silu(y)

        y = conv1d(
            y,
            pointwiseConv2Weight,
            stride: 1,
            padding: 0
        ) + pointwiseConv2Bias

        eval(y)
        return y
    }
}

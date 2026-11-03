import Foundation
@preconcurrency import MLX

public final class GigaAMLayerNorm: @unchecked Sendable {
    public let weight: MLXArray
    public let bias: MLXArray
    public let eps: Float

    public init(weight: MLXArray, bias: MLXArray, eps: Float = 1e-5) {
        self.weight = weight
        self.bias = bias
        self.eps = eps
    }

    public convenience init(store: GigaAMTensorStore, prefix: String, eps: Float = 1e-5) throws {
        self.init(
            weight: try store.load("\(prefix).weight"),
            bias: try store.load("\(prefix).bias"),
            eps: eps
        )
    }

    public func forward(_ x: MLXArray) -> MLXArray {
        MLXFast.layerNorm(x, weight: weight, bias: bias, eps: eps)
    }
}

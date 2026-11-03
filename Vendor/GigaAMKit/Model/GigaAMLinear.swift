import Foundation
@preconcurrency import MLX

public final class GigaAMLinear: @unchecked Sendable {
    public let weight: MLXArray
    public let bias: MLXArray?

    public init(weight: MLXArray, bias: MLXArray? = nil) {
        self.weight = weight
        self.bias = bias
    }

    public convenience init(store: GigaAMTensorStore, weightName: String, biasName: String? = nil) throws {
        let weight = try store.load(weightName)
        let bias = try biasName.map { try store.load($0) }
        self.init(weight: weight, bias: bias)
    }

    public func forward(_ x: MLXArray) -> MLXArray {
        var y = matmul(x, transposed(weight))

        if let bias {
            y = y + bias
        }

        return y
    }
}

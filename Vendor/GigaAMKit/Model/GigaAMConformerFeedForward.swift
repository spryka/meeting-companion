import Foundation
@preconcurrency import MLX
@preconcurrency import MLXNN

public final class GigaAMConformerFeedForward: @unchecked Sendable {
    private let linear1: GigaAMLinear
    private let linear2: GigaAMLinear

    public init(store: GigaAMTensorStore, prefix: String) throws {
        self.linear1 = try GigaAMLinear(
            store: store,
            weightName: "\(prefix).linear1.weight",
            biasName: "\(prefix).linear1.bias"
        )

        self.linear2 = try GigaAMLinear(
            store: store,
            weightName: "\(prefix).linear2.weight",
            biasName: "\(prefix).linear2.bias"
        )
    }

    public func forward(_ x: MLXArray) -> MLXArray {
        linear2.forward(silu(linear1.forward(x)))
    }
}

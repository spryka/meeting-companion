import Foundation
@preconcurrency import MLX

public final class GigaAMConformerEncoderStack: @unchecked Sendable {
    public let layers: [GigaAMConformerLayer]

    public init(store: GigaAMTensorStore, layerCount: Int = 16) throws {
        self.layers = try (0..<layerCount).map { index in
            try GigaAMConformerLayer(store: store, layerIndex: index)
        }
    }

    public func forward(
        _ input: MLXArray,
        checkpointLayers: Set<Int> = []
    ) -> (output: MLXArray, checkpoints: [Int: MLXArray]) {
        var x = input
        var checkpoints: [Int: MLXArray] = [:]

        for (index, layer) in layers.enumerated() {
            x = layer.forward(x)
            eval(x)

            if checkpointLayers.contains(index) {
                checkpoints[index] = x
            }
        }

        return (x, checkpoints)
    }
}

import Foundation
@preconcurrency import MLX
@preconcurrency import MLXNN

public final class GigaAMRNNTJoint: @unchecked Sendable {
    public let encHidden: Int
    public let predHidden: Int
    public let jointHidden: Int
    public let numClasses: Int

    private let encWeight: MLXArray
    private let encBias: MLXArray

    private let predWeight: MLXArray
    private let predBias: MLXArray

    private let outWeight: MLXArray
    private let outBias: MLXArray

    public init(
        store: GigaAMTensorStore,
        encHidden: Int = 768,
        predHidden: Int = 320,
        jointHidden: Int = 320,
        numClasses: Int = 1025
    ) throws {
        self.encHidden = encHidden
        self.predHidden = predHidden
        self.jointHidden = jointHidden
        self.numClasses = numClasses

        self.encWeight = try store.load("model.head.joint.enc.weight")
        self.encBias = try store.load("model.head.joint.enc.bias")

        self.predWeight = try store.load("model.head.joint.pred.weight")
        self.predBias = try store.load("model.head.joint.pred.bias")

        self.outWeight = try store.load("model.head.joint.joint_net.1.weight")
        self.outBias = try store.load("model.head.joint.joint_net.1.bias")
    }

    public func forward(
        encoderOut: MLXArray,
        decoderOut: MLXArray
    ) -> MLXArray {
        // Python:
        // enc = self.enc(encoder_out).unsqueeze(2)
        // pred = self.pred(decoder_out).unsqueeze(1)
        // return self.joint_net(enc + pred).log_softmax(-1)

        let encProjected = matmul(encoderOut, transposed(encWeight)) + encBias
        let predProjected = matmul(decoderOut, transposed(predWeight)) + predBias

        let enc4d = expandedDimensions(encProjected, axis: 2)
        let pred4d = expandedDimensions(predProjected, axis: 1)

        let hidden = relu(enc4d + pred4d)
        let logits = matmul(hidden, transposed(outWeight)) + outBias
        let logProbs = logSoftmax(logits, axis: -1)

        eval(logProbs)
        return logProbs
    }
}

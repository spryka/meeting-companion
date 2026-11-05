import Foundation
@preconcurrency import MLX

public final class GigaAMRotarySelfAttention: @unchecked Sendable {
    public let nHeads: Int
    public let headDim: Int
    public let modelDim: Int
    public let ropeBase: Int

    private let linearQ: GigaAMLinear
    private let linearK: GigaAMLinear
    private let linearV: GigaAMLinear
    private let linearOut: GigaAMLinear

    public init(
        store: GigaAMTensorStore,
        prefix: String,
        nHeads: Int = 16,
        modelDim: Int = 768,
        ropeBase: Int = 5000
    ) throws {
        self.nHeads = nHeads
        self.modelDim = modelDim
        self.headDim = modelDim / nHeads
        self.ropeBase = ropeBase

        self.linearQ = try GigaAMLinear(
            store: store,
            weightName: "\(prefix).linear_q.weight",
            biasName: "\(prefix).linear_q.bias"
        )

        self.linearK = try GigaAMLinear(
            store: store,
            weightName: "\(prefix).linear_k.weight",
            biasName: "\(prefix).linear_k.bias"
        )

        self.linearV = try GigaAMLinear(
            store: store,
            weightName: "\(prefix).linear_v.weight",
            biasName: "\(prefix).linear_v.bias"
        )

        self.linearOut = try GigaAMLinear(
            store: store,
            weightName: "\(prefix).linear_out.weight",
            biasName: "\(prefix).linear_out.bias"
        )
    }

    public func forward(_ x: MLXArray) -> MLXArray {
        // Python RotaryPositionMultiHeadAttention.forward:
        //
        // b, t, _ = value.size()
        // query = query.transpose(0, 1).view(t, b, h, d_k)
        // key   = key.transpose(0, 1).view(t, b, h, d_k)
        // value = value.transpose(0, 1).view(t, b, h, d_k)
        //
        // query, key = apply_rotary_pos_emb(query, key, cos, sin)
        //
        // q, k, v = forward_qkv(
        //   query.view(t, b, h*d).transpose(0, 1),
        //   key.view(t, b, h*d).transpose(0, 1),
        //   value.view(t, b, h*d).transpose(0, 1),
        // )
        //
        // scores = q @ k.transpose(-2, -1) / sqrt(d_k)
        // attn = softmax(scores, dim=-1)
        // context = attn @ v
        // output = linear_out(context.transpose(1, 2).reshape(b, t, h*d))

        let shape = x.shape
        let batchSize = shape[0]
        let timeSteps = shape[1]

        let xtb = transposed(x, 1, 0, 2)

        var query = xtb.reshaped([timeSteps, batchSize, nHeads, headDim])
        var key = xtb.reshaped([timeSteps, batchSize, nHeads, headDim])
        let value = xtb.reshaped([timeSteps, batchSize, nHeads, headDim])

        let rope = makeRotaryEmbedding(length: timeSteps)
        query = applyRotary(query, cos: rope.cos, sin: rope.sin)
        key = applyRotary(key, cos: rope.cos, sin: rope.sin)

        let queryFlat = query
            .reshaped([timeSteps, batchSize, modelDim])
            .transposed(1, 0, 2)

        let keyFlat = key
            .reshaped([timeSteps, batchSize, modelDim])
            .transposed(1, 0, 2)

        let valueFlat = value
            .reshaped([timeSteps, batchSize, modelDim])
            .transposed(1, 0, 2)

        let q = linearQ.forward(queryFlat)
            .reshaped([batchSize, timeSteps, nHeads, headDim])
            .transposed(0, 2, 1, 3)

        let k = linearK.forward(keyFlat)
            .reshaped([batchSize, timeSteps, nHeads, headDim])
            .transposed(0, 2, 1, 3)

        let v = linearV.forward(valueFlat)
            .reshaped([batchSize, timeSteps, nHeads, headDim])
            .transposed(0, 2, 1, 3)

        let scale = Float(1.0 / Foundation.sqrt(Double(headDim)))
        let scores = matmul(q, transposed(k, 0, 1, 3, 2) * scale)
        let attn = softmax(scores, axis: -1)
        let context = matmul(attn, v)

        let contextFlat = context
            .transposed(0, 2, 1, 3)
            .reshaped([batchSize, timeSteps, modelDim])

        let output = linearOut.forward(contextFlat)
        eval(output)
        return output
    }

    private func makeRotaryEmbedding(length: Int) -> (cos: MLXArray, sin: MLXArray) {
        let halfDim = headDim / 2
        var cosValues: [Float] = []
        var sinValues: [Float] = []
        cosValues.reserveCapacity(length * headDim)
        sinValues.reserveCapacity(length * headDim)

        for position in 0..<length {
            for dimIndex in 0..<headDim {
                let freqIndex = dimIndex < halfDim ? dimIndex : dimIndex - halfDim
                let exponent = Double(2 * freqIndex) / Double(headDim)
                let invFreq = 1.0 / Foundation.pow(Double(ropeBase), exponent)
                let value = Double(position) * invFreq

                cosValues.append(Float(Foundation.cos(value)))
                sinValues.append(Float(Foundation.sin(value)))
            }
        }

        let shape = [length, 1, 1, headDim]
        return (
            cos: MLXArray(cosValues, shape),
            sin: MLXArray(sinValues, shape)
        )
    }

    private func applyRotary(_ x: MLXArray, cos: MLXArray, sin: MLXArray) -> MLXArray {
        let halfDim = headDim / 2

        let x1 = x[0 ..< x.shape[0], 0 ..< x.shape[1], 0 ..< x.shape[2], 0 ..< halfDim]
        let x2 = x[0 ..< x.shape[0], 0 ..< x.shape[1], 0 ..< x.shape[2], halfDim ..< headDim]

        let rotated = concatenated([-x2, x1], axis: -1)

        return (x * cos) + (rotated * sin)
    }
}

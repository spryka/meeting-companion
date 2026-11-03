import Foundation
@preconcurrency import MLX

public struct GigaAMRNNTDecoderState {
    public let h: MLXArray
    public let c: MLXArray

    public init(h: MLXArray, c: MLXArray) {
        self.h = h
        self.c = c
    }
}

public struct GigaAMRNNTDecoderOutput {
    public let dec: MLXArray
    public let state: GigaAMRNNTDecoderState

    public init(dec: MLXArray, state: GigaAMRNNTDecoderState) {
        self.dec = dec
        self.state = state
    }
}

public final class GigaAMRNNTDecoder: @unchecked Sendable {
    public let blankId: Int
    public let hiddenSize: Int

    private let embedWeight: MLXArray
    private let wIH: MLXArray
    private let wHH: MLXArray
    private let bIH: MLXArray
    private let bHH: MLXArray

    public init(
        store: GigaAMTensorStore,
        blankId: Int = 1024,
        hiddenSize: Int = 320
    ) throws {
        self.blankId = blankId
        self.hiddenSize = hiddenSize

        self.embedWeight = try store.load("model.head.decoder.embed.weight")
        self.wIH = try store.load("model.head.decoder.lstm.weight_ih_l0")
        self.wHH = try store.load("model.head.decoder.lstm.weight_hh_l0")
        self.bIH = try store.load("model.head.decoder.lstm.bias_ih_l0")
        self.bHH = try store.load("model.head.decoder.lstm.bias_hh_l0")
    }

    public func zeroState(batchSize: Int = 1) -> GigaAMRNNTDecoderState {
        let shape = [1, batchSize, hiddenSize]

        return GigaAMRNNTDecoderState(
            h: MLXArray.zeros(shape, dtype: .float32),
            c: MLXArray.zeros(shape, dtype: .float32)
        )
    }

    public func predict(
        tokenId: Int?,
        state: GigaAMRNNTDecoderState?,
        batchSize: Int = 1
    ) throws -> GigaAMRNNTDecoderOutput {
        let currentState = state ?? zeroState(batchSize: batchSize)

        let embedding: MLXArray

        if let tokenId {
            embedding = embedWeight[tokenId ..< tokenId + 1, 0 ..< hiddenSize]
                .reshaped([batchSize, 1, hiddenSize])
                .asType(Float.self)
        } else {
            embedding = MLXArray.zeros([batchSize, 1, hiddenSize], dtype: .float32)
        }

        // PyTorch RNNTDecoder.forward:
        // emb = self.embed(x)
        // g, (h, c) = self.lstm(emb.transpose(0, 1), (h, c))
        // return g.transpose(0, 1), h, c
        //
        // Для одного шага и batch=1:
        // embedding: [1, 1, 320]
        // h/c:       [1, 1, 320]
        let gates =
            matmul(embedding, transposed(wIH)) + bIH +
            matmul(currentState.h, transposed(wHH)) + bHH

        // PyTorch LSTM gate order: i, f, g, o
        let iGate = gates[0 ..< 1, 0 ..< 1, 0 ..< hiddenSize]
        let fGate = gates[0 ..< 1, 0 ..< 1, hiddenSize ..< hiddenSize * 2]
        let gGate = gates[0 ..< 1, 0 ..< 1, hiddenSize * 2 ..< hiddenSize * 3]
        let oGate = gates[0 ..< 1, 0 ..< 1, hiddenSize * 3 ..< hiddenSize * 4]

        let i = sigmoid(iGate)
        let f = sigmoid(fGate)
        let g = tanh(gGate)
        let o = sigmoid(oGate)

        let c1 = f * currentState.c + i * g
        let h1 = o * tanh(c1)

        eval(h1)
        eval(c1)

        return GigaAMRNNTDecoderOutput(
            dec: h1,
            state: GigaAMRNNTDecoderState(h: h1, c: c1)
        )
    }
}

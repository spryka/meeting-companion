import Foundation
import Accelerate
@preconcurrency import MLX

// Apple Silicon shares MLX memory; a CPU reduction avoids one GPU launch per token step.
func bestRNNTToken(_ logProbs: MLXArray) throws -> (token: Int, logProb: Float) {
    let flat = logProbs.dtype == .float32 ? logProbs : logProbs.asType(.float32)
    guard flat.size > 0 else {
        throw GigaAMError.invalidManifest("RNNT step produced empty log_probs")
    }
    return withExtendedLifetime(flat) {
        let data = flat.asData(access: .noCopyIfContiguous)
        return data.data.withUnsafeBytes { bytes in
            let values = bytes.bindMemory(to: Float.self)
            var score: Float = 0
            var index: vDSP_Length = 0
            vDSP_maxvi(values.baseAddress!, 1, &score, &index, vDSP_Length(values.count))
            return (Int(index), score)
        }
    }
}

public struct GigaAMRNNTStepResult {
    public let logProbs: MLXArray
    public let decoderOutput: MLXArray
    public let state: GigaAMRNNTDecoderState
    public let bestToken: Int
    public let bestLogProb: Float
    public let isBlank: Bool
}

public struct GigaAMRNNTStepTiming: Sendable {
    public let decoderSec: TimeInterval
    public let jointSec: TimeInterval
    public let readbackSec: TimeInterval
    public let totalSec: TimeInterval
}

public struct GigaAMRNNTTimedStepResult {
    public let result: GigaAMRNNTStepResult
    public let timing: GigaAMRNNTStepTiming
}

public final class GigaAMRNNTHead: @unchecked Sendable {
    public let decoder: GigaAMRNNTDecoder
    public let joint: GigaAMRNNTJoint
    public let blankId: Int

    public init(store: GigaAMTensorStore, blankId: Int = 1024) throws {
        self.blankId = blankId
        self.decoder = try GigaAMRNNTDecoder(store: store, blankId: blankId)
        self.joint = try GigaAMRNNTJoint(store: store)
    }

    public func step(
        encoderOut: MLXArray,
        tokenId: Int?,
        state: GigaAMRNNTDecoderState?
    ) throws -> GigaAMRNNTStepResult {
        try stepTimed(
            encoderOut: encoderOut,
            tokenId: tokenId,
            state: state
        ).result
    }

    public func stepTimed(
        encoderOut: MLXArray,
        tokenId: Int?,
        state: GigaAMRNNTDecoderState?
    ) throws -> GigaAMRNNTTimedStepResult {
        let totalStart = Self.now()

        let decoderStart = Self.now()
        let decoderResult = try decoder.predict(tokenId: tokenId, state: state)
        let decoderSec = Self.now() - decoderStart

        let jointStart = Self.now()
        let logProbs = joint.forward(
            encoderOut: encoderOut,
            decoderOut: decoderResult.dec
        )
        let jointSec = Self.now() - jointStart

        let readbackStart = Self.now()
        let best = try bestRNNTToken(logProbs)

        let readbackSec = Self.now() - readbackStart
        let totalSec = Self.now() - totalStart

        return GigaAMRNNTTimedStepResult(
            result: GigaAMRNNTStepResult(
                logProbs: logProbs,
                decoderOutput: decoderResult.dec,
                state: decoderResult.state,
                bestToken: best.token,
                bestLogProb: best.logProb,
                isBlank: best.token == blankId
            ),
            timing: GigaAMRNNTStepTiming(
                decoderSec: decoderSec,
                jointSec: jointSec,
                readbackSec: readbackSec,
                totalSec: totalSec
            )
        )
    }

    private static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}

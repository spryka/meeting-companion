import Foundation
@preconcurrency import MLX

public struct RNNTGreedyDecoderConfig: Sendable {
    public let blankId: Int
    public let maxSymbolsPerFrame: Int

    public init(blankId: Int = 1024, maxSymbolsPerFrame: Int = 10) {
        self.blankId = blankId
        self.maxSymbolsPerFrame = maxSymbolsPerFrame
    }
}

public struct RNNTGreedyStepTrace: Sendable {
    public let timeIndex: Int
    public let symbolIndex: Int
    public let token: Int
    public let logProb: Float
    public let isBlank: Bool
}

public struct RNNTGreedyDecodeResult: Sendable {
    public let tokens: [Int]
    public let steps: [RNNTGreedyStepTrace]
}

public struct RNNTGreedyDecodeTiming: Sendable {
    public let stepCount: Int
    public let decoderSec: TimeInterval
    public let jointSec: TimeInterval
    public let readbackSec: TimeInterval
    public let totalStepSec: TimeInterval
}

public struct RNNTGreedyTimedDecodeResult: Sendable {
    public let result: RNNTGreedyDecodeResult
    public let timing: RNNTGreedyDecodeTiming
}

public final class RNNTGreedyDecoder: @unchecked Sendable {
    public let config: RNNTGreedyDecoderConfig

    public init(config: RNNTGreedyDecoderConfig = RNNTGreedyDecoderConfig()) {
        self.config = config
    }

    public func decode(
        head: GigaAMRNNTHead,
        encoded: MLXArray,
        encodedLength: Int
    ) throws -> RNNTGreedyDecodeResult {
        try decodeTimed(
            head: head,
            encoded: encoded,
            encodedLength: encodedLength
        ).result
    }

    public func decodeTimed(
        head: GigaAMRNNTHead,
        encoded: MLXArray,
        encodedLength: Int
    ) throws -> RNNTGreedyTimedDecodeResult {
        guard encoded.shape.count == 3 else {
            throw GigaAMError.invalidArguments(
                "Expected encoded shape [B, C, T], got \(encoded.shape)"
            )
        }

        let batchSize = encoded.shape[0]
        let channels = encoded.shape[1]
        let timeSteps = encoded.shape[2]

        guard batchSize == 1 else {
            throw GigaAMError.invalidArguments(
                "RNNT greedy currently supports batchSize=1, got \(batchSize)"
            )
        }

        let effectiveLength = min(encodedLength, timeSteps)

        // [1, C, T] -> [1, T, C]
        let encodedBTC = transposed(encoded, 0, 2, 1)

        var tokens: [Int] = []
        var steps: [RNNTGreedyStepTrace] = []

        var decoderState: GigaAMRNNTDecoderState?
        var lastToken: Int?

        // Cache predictor output for the current (lastToken, decoderState).
        //
        // Correctness:
        // - On blank, decoderState and lastToken are NOT updated, so predictor input
        //   remains identical on the next frame. Reusing g/hidden is valid.
        // - On non-blank, decoderState and lastToken change, so cache is invalidated.
        var cachedDecoderResult: GigaAMRNNTDecoderOutput?

        var stepCount = 0
        var decoderSec = TimeInterval(0)
        var jointSec = TimeInterval(0)
        var readbackSec = TimeInterval(0)
        var totalStepSec = TimeInterval(0)

        for timeIndex in 0..<effectiveLength {
            let encoderFrame = encodedBTC[
                0 ..< 1,
                timeIndex ..< timeIndex + 1,
                0 ..< channels
            ]

            var notBlank = true
            var newSymbols = 0

            while notBlank && newSymbols < config.maxSymbolsPerFrame {
                let stepStart = Self.now()

                let decoderResult: GigaAMRNNTDecoderOutput

                if let cachedDecoderResult {
                    decoderResult = cachedDecoderResult
                } else {
                    let decoderStart = Self.now()
                    decoderResult = try head.decoder.predict(
                        tokenId: lastToken,
                        state: decoderState
                    )
                    decoderSec += Self.now() - decoderStart
                    cachedDecoderResult = decoderResult
                }

                let jointStart = Self.now()
                let logProbs = head.joint.forward(
                    encoderOut: encoderFrame,
                    decoderOut: decoderResult.dec
                )
                jointSec += Self.now() - jointStart

                let readbackStart = Self.now()
                let best = try bestRNNTToken(logProbs)

                readbackSec += Self.now() - readbackStart

                let bestToken = best.token
                let bestLogProb = best.logProb
                let isBlank = bestToken == config.blankId

                stepCount += 1
                totalStepSec += Self.now() - stepStart

                steps.append(
                    RNNTGreedyStepTrace(
                        timeIndex: timeIndex,
                        symbolIndex: newSymbols,
                        token: bestToken,
                        logProb: bestLogProb,
                        isBlank: isBlank
                    )
                )

                if isBlank {
                    notBlank = false
                    // Keep cachedDecoderResult. It is still valid because blank does
                    // not commit decoderResult.state.
                } else {
                    tokens.append(bestToken)
                    decoderState = decoderResult.state
                    lastToken = bestToken
                    newSymbols += 1

                    // Predictor input changed, so cached g/hidden is no longer valid.
                    cachedDecoderResult = nil
                }
            }
        }

        return RNNTGreedyTimedDecodeResult(
            result: RNNTGreedyDecodeResult(tokens: tokens, steps: steps),
            timing: RNNTGreedyDecodeTiming(
                stepCount: stepCount,
                decoderSec: decoderSec,
                jointSec: jointSec,
                readbackSec: readbackSec,
                totalStepSec: totalStepSec
            )
        )
    }

    private static func now() -> TimeInterval {
        Double(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000
    }
}
